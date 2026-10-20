#!/usr/bin/env bash
#
# 构建 GEOFlow 生产镜像并推送到镜像仓库（默认阿里云 ACR）。
#
# 产出两个镜像：
#   geoflow-app-prod  PHP 8.4 FPM + 业务代码 + Composer 依赖
#   geoflow-web-prod  Nginx + 编译后的前端静态资源
#
# 版本号策略：<version.json 版本>-<短 commit>，例如 3.1.0-a1b2c3d。
# 同时打 :latest 便于快速部署，但生产环境建议在 .env 里锁定具体版本号，
# 以便回滚与问题追溯。
#
# 用法：
#   bash deploy-scripts/release-images.sh
#   REGISTRY=registry.cn-chengdu.aliyuncs.com NS=kintreda/geoflow \
#     bash deploy-scripts/release-images.sh
#   PLATFORMS=linux/amd64,linux/arm64 bash deploy-scripts/release-images.sh
#   VERSION=3.1.0-custom bash deploy-scripts/release-images.sh
#   SKIP_PUSH=1 bash deploy-scripts/release-images.sh          # 只构建不推送
#
# 环境变量：
#   REGISTRY      镜像仓库地址，默认 registry.cn-chengdu.aliyuncs.com
#   NS            命名空间（仓库路径），默认 kintreda/geoflow
#   VERSION       镜像版本号，默认取 version.json + 短 commit
#   PLATFORMS     多架构列表，默认 linux/amd64
#   REGISTRY_USER 登录用户名（也可用 DOCKER_USERNAME）
#   REGISTRY_PASS 登录密码（也可用 DOCKER_PASSWORD）；不设则跳过登录
#   BUILDER_NAME  buildx builder 名称，默认 geoflow-builder
#   SKIP_PUSH     设为 1 时只构建不推送
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

REGISTRY="${REGISTRY:-registry.cn-chengdu.aliyuncs.com}"
NS="${NS:-kintreda/geoflow}"
PLATFORMS="${PLATFORMS:-linux/amd64}"
BUILDER_NAME="${BUILDER_NAME:-geoflow-builder}"
SKIP_PUSH="${SKIP_PUSH:-0}"

COMPOSER_IMAGE="${COMPOSER_IMAGE:-composer:2}"
PHP_FPM_IMAGE="${PHP_FPM_IMAGE:-php:8.4-fpm-bookworm}"
NGINX_IMAGE="${NGINX_IMAGE:-nginx:1.31.1-alpine}"
PECL_REDIS_VERSION="${PECL_REDIS_VERSION:-6.3.0}"
COMPOSER_PACKAGIST_MIRROR="${COMPOSER_PACKAGIST_MIRROR:-}"

REGISTRY_USER="${REGISTRY_USER:-${DOCKER_USERNAME:-}}"
REGISTRY_PASS="${REGISTRY_PASS:-${DOCKER_PASSWORD:-}}"

cd "${PROJECT_DIR}"

log() { printf '\033[1;34m[release]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 版本号
# ---------------------------------------------------------------------------
resolve_version() {
  if [[ -n "${VERSION:-}" ]]; then
    echo "${VERSION}"
    return
  fi

  local base="unknown"
  if [[ -f version.json ]]; then
    base="$(python3 -c "
import json
try:
    print(json.load(open('version.json', encoding='utf-8')).get('version', 'unknown'))
except Exception:
    print('unknown')
" 2>/dev/null || echo "unknown")"
  fi

  local short=""
  if git rev-parse --git-dir >/dev/null 2>&1; then
    short="$(git rev-parse --short HEAD 2>/dev/null || echo "")"
  fi

  if [[ -n "${short}" ]]; then
    echo "${base}-${short}"
  else
    echo "${base}"
  fi
}

VERSION="$(resolve_version)"
APP_IMAGE="${REGISTRY}/${NS}/geoflow-app-prod:${VERSION}"
WEB_IMAGE="${REGISTRY}/${NS}/geoflow-web-prod:${VERSION}"

echo "=============================================="
echo "  GEOFlow 镜像发布"
echo "=============================================="
echo "  Registry   : ${REGISTRY}"
echo "  Namespace  : ${NS}"
echo "  Version    : ${VERSION}"
echo "  Platforms  : ${PLATFORMS}"
echo "  App image  : ${APP_IMAGE}"
echo "  Web image  : ${WEB_IMAGE}"
echo "=============================================="
echo ""

# ---------------------------------------------------------------------------
# 登录
# ---------------------------------------------------------------------------
if [[ "${SKIP_PUSH}" != "1" ]]; then
  if [[ -n "${REGISTRY_USER}" && -n "${REGISTRY_PASS}" ]]; then
    log "登录镜像仓库: ${REGISTRY}"
    # 密码用 --password-stdin 传入，避免出现在进程列表和 shell 历史里
    printf '%s' "${REGISTRY_PASS}" | docker login --username "${REGISTRY_USER}" --password-stdin "${REGISTRY}"
  elif [[ -n "${REGISTRY_USER}" ]]; then
    log "未提供密码，改为交互式登录"
    docker login --username "${REGISTRY_USER}" "${REGISTRY}"
  else
    warn "未设置 REGISTRY_USER / REGISTRY_PASS，跳过登录。"
    warn "若仓库为私有，push 会失败。可执行: docker login ${REGISTRY}"
  fi
fi

# ---------------------------------------------------------------------------
# buildx builder
# ---------------------------------------------------------------------------
if ! docker buildx version >/dev/null 2>&1; then
  fail "缺少 buildx。安装 Docker Buildx 后重试。"
fi

if ! docker buildx inspect "${BUILDER_NAME}" >/dev/null 2>&1; then
  log "创建 buildx builder: ${BUILDER_NAME}"
  docker buildx create --name "${BUILDER_NAME}" --driver docker-container --use
else
  docker buildx use "${BUILDER_NAME}"
fi
docker buildx inspect --bootstrap >/dev/null

# 多架构时不能用 --load（本地镜像库装不下多架构 manifest）
push_flag="--push"
if [[ "${SKIP_PUSH}" == "1" ]]; then
  push_flag="--load"
  if [[ "${PLATFORMS}" == *","* ]]; then
    warn "SKIP_PUSH=1 且为多架构，--load 不支持多架构，改为仅构建当前架构"
    PLATFORMS="linux/amd64"
  fi
fi

# ---------------------------------------------------------------------------
# 构建 app 镜像
# ---------------------------------------------------------------------------
log "构建 app 镜像 (${PLATFORMS})"
docker buildx build --platform "${PLATFORMS}" \
  -f docker/Dockerfile.prod \
  -t "${APP_IMAGE}" \
  -t "${REGISTRY}/${NS}/geoflow-app-prod:latest" \
  --build-arg COMPOSER_IMAGE="${COMPOSER_IMAGE}" \
  --build-arg PHP_FPM_IMAGE="${PHP_FPM_IMAGE}" \
  --build-arg PECL_REDIS_VERSION="${PECL_REDIS_VERSION}" \
  --build-arg COMPOSER_PACKAGIST_MIRROR="${COMPOSER_PACKAGIST_MIRROR}" \
  ${push_flag} .

# ---------------------------------------------------------------------------
# 构建 web 镜像
# ---------------------------------------------------------------------------
log "构建 web 镜像 (${PLATFORMS})"
docker buildx build --platform "${PLATFORMS}" \
  -f docker/nginx/Dockerfile.prod \
  -t "${WEB_IMAGE}" \
  -t "${REGISTRY}/${NS}/geoflow-web-prod:latest" \
  --build-arg NGINX_IMAGE="${NGINX_IMAGE}" \
  ${push_flag} .

echo ""
log "发布完成："
echo "    ${APP_IMAGE}"
echo "    ${WEB_IMAGE}"
echo "    ${REGISTRY}/${NS}/geoflow-app-prod:latest"
echo "    ${REGISTRY}/${NS}/geoflow-web-prod:latest"
echo ""
echo ">>> 部署时在 .env 中锁定版本："
echo "    GEOFLOW_APP_IMAGE=${APP_IMAGE}"
echo "    GEOFLOW_WEB_IMAGE=${WEB_IMAGE}"
