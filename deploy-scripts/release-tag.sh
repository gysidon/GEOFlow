#!/usr/bin/env bash
#
# 发布 GEOFlow 新版本：打 v$version tag 并推送到 fork 仓库，
# 由阿里云 ACR 的「代码变更时自动构建镜像」规则自动构建两个镜像。
#
# ACR 内置构建规则（每个镜像仓库各配一条）：
#   分支/标签：       tags: v$version
#   构建上下文目录：   /
#   Dockerfile文件名： Dockerfile        （app 仓库）
#                    Dockerfile.web     （web 仓库）
#   镜像版本：       $version
#
# 触发效果：源码 tag 为 v3.1.0 时，ACR 自定义规则（镜像版本固定 latest）自动构建镜像。
#   registry.cn-chengdu.aliyuncs.com/kintreda/geoflow-app:3.1.0
#   registry.cn-chengdu.aliyuncs.com/kintreda/geoflow-web:3.1.0
#
# 用法：
#   bash deploy-scripts/release-tag.sh                 # 用 version.json 里的版本号
#   VERSION=3.1.1 bash deploy-scripts/release-tag.sh   # 指定版本号
#   DRY_RUN=1 bash deploy-scripts/release-tag.sh       # 只打印不执行
#   VERIFY=1 bash deploy-scripts/release-tag.sh        # 打完 tag 后自动校验构建产物
#
# 环境变量：
#   VERSION   镜像版本号，默认取 version.json 的 version 字段
#   REMOTE    推送目标远端，默认 origin
#   BRANCH    提交与打 tag 所在的分支，默认 custom
#   DRY_RUN   设为 1 时只打印将要执行的动作
#   VERIFY    设为 1 时推送后自动校验 ACR 构建出的两个镜像内容是否正确
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_DIR}"

REMOTE="${REMOTE:-origin}"
BRANCH="${BRANCH:-custom}"
DRY_RUN="${DRY_RUN:-0}"

log()  { printf '\033[1;34m[release]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. 解析版本号
# ---------------------------------------------------------------------------
if [[ -z "${VERSION:-}" ]]; then
  [[ -f version.json ]] || fail "找不到 version.json，请用 VERSION=3.1.1 指定版本号。"
  VERSION="$(python3 -c "
import json
print(json.load(open('version.json', encoding='utf-8'))['version'])
" 2>/dev/null)" || fail "解析 version.json 失败，请用 VERSION=3.1.1 指定版本号。"
fi

# 只允许数字与点，避免 tag 名非法
[[ "${VERSION}" =~ ^[0-9]+(\.[0-9]+)*$ ]] || fail "版本号格式非法: ${VERSION}（只允许数字和点，如 3.1.0）"

TAG="v${VERSION}"

# ---------------------------------------------------------------------------
# 2. 前置检查
# ---------------------------------------------------------------------------
git rev-parse --git-dir >/dev/null 2>&1 || fail "当前目录不是 git 仓库。"
[[ -f Dockerfile ]]     || fail "缺少根目录 Dockerfile（app 镜像，ACR 构建入口）。"
[[ -f Dockerfile.web ]] || fail "缺少根目录 Dockerfile.web（web 镜像，ACR 构建入口）。"

# 拉取远端 tag 状态用于查重。网络不通时不能无限等待——发版流程最忌讳卡死。
# 部分精简环境没有 timeout 命令，此时退化为不拉取（用本地状态判断）。
if command -v timeout >/dev/null 2>&1; then
  fetch_cmd=(timeout 30 git fetch "${REMOTE}" --tags)
else
  warn "系统无 timeout 命令，跳过远端 tag 拉取（用本地 tag 状态判断）。"
  fetch_cmd=()
fi

if [[ ${#fetch_cmd[@]} -gt 0 ]] && ! "${fetch_cmd[@]}" >/dev/null 2>&1; then
  warn "拉取远端 tag 失败或超时（网络问题），改用本地 tag 状态判断。"
  warn "若远端已存在同名 tag，推送时会被拒绝，此时需提高版本号或先删除远端 tag。"
fi

if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null 2>&1; then
  fail "tag ${TAG} 已存在。ACR 不会重复构建已存在的 tag，请提升版本号或先删除该 tag。"
fi

if [[ -n "$(git status --porcelain)" ]]; then
  fail "工作区有未提交改动。发布前先提交并推送，否则 ACR 构建的代码与 tag 不一致。"
fi

current_branch="$(git branch --show-current)"
if [[ "${current_branch}" != "${BRANCH}" ]]; then
  warn "当前分支是 ${current_branch}，预期 ${BRANCH}。若确认无误可忽略。"
fi

# ---------------------------------------------------------------------------
# 3. 确认远端与提交
# ---------------------------------------------------------------------------
remote_url="$(git remote get-url "${REMOTE}" 2>/dev/null || echo '')"
[[ -n "${remote_url}" ]] || fail "远端 ${REMOTE} 不存在。"

echo "=============================================="
echo "  GEOFlow 版本发布"
echo "=============================================="
echo "  远端    : ${REMOTE} (${remote_url})"
echo "  分支    : ${current_branch}"
echo "  版本号  : ${VERSION}"
echo "  Tag     : ${TAG}"
echo "  Commit  : $(git rev-parse --short HEAD)"
echo "=============================================="
echo ""

if [[ "${DRY_RUN}" == "1" ]]; then
  log "DRY_RUN=1，以下动作不会执行："
  echo "  git tag -a ${TAG} -m \"Release ${VERSION}\""
  echo "  git push ${REMOTE} ${TAG}"
  echo ""
  log "预期产出的镜像："
  echo "  <ACR地址>/kintreda/geoflow-app:latest"
  echo "  <ACR地址>/kintreda/geoflow-web:latest"
  exit 0
fi

# ---------------------------------------------------------------------------
# 4. 打 tag 并推送
# ---------------------------------------------------------------------------
log "创建 tag: ${TAG}"
git tag -a "${TAG}" -m "Release ${VERSION}" -m "由 deploy-scripts/release-tag.sh 创建，触发 ACR 自动构建 ${VERSION} 版本镜像。"

log "推送 tag 到 ${REMOTE}"
if ! git push "${REMOTE}" "${TAG}"; then
  # 推送失败则回滚本地 tag，避免留下无法推送的悬空 tag
  git tag -d "${TAG}" >/dev/null 2>&1 || true
  fail "推送 tag 失败，已删除本地 tag ${TAG}。请检查网络与远端权限。"
fi

echo ""
log "tag 推送成功，ACR 将自动开始构建："
echo "    <ACR地址>/kintreda/geoflow-app:latest"
echo "    <ACR地址>/kintreda/geoflow-web:latest"
echo ""
echo ">>> 查看构建进度：阿里云控制台 → 容器镜像服务 → 镜像仓库 → 构建"
echo ">>> 构建完成后，部署机 .env 中镜像锁定为 latest："
echo "    GEOFLOW_APP_IMAGE=<ACR地址>/kintreda/geoflow-app:latest"
echo "    GEOFLOW_WEB_IMAGE=<ACR地址>/kintreda/geoflow-web:latest"
echo ""

# ---------------------------------------------------------------------------
# 5. 校验构建产物（可选）
# ---------------------------------------------------------------------------
# 自定义规则镜像版本固定为 latest，app/web 各走自己的 Dockerfile。构建完成后
# 立即校验，避免部署时才发现 web 容器起不来（web 应是 nginx、app 应是 php-fpm）。
if [[ "${VERIFY:-0}" == "1" ]]; then
  log "等待构建完成并校验产物（VERIFY=1）……"
  log "提示：ACR 构建约需 10-20 分钟，脚本会持续重试"
  verify_script="${SCRIPT_DIR}/verify-acr-images.sh"
  if [[ -f "${verify_script}" ]]; then
    for attempt in $(seq 1 30); do
      if bash "${verify_script}" "${VERSION}"; then
        echo ""
        log "镜像产物校验通过"
        exit 0
      fi
      [[ "${attempt}" -lt 30 ]] && { echo "  第 ${attempt} 次校验未通过，60 秒后重试……"; sleep 60; }
    done
    warn "多次校验仍未通过。构建可能还在进行，或 ACR 规则需要修正（见 deploy/geoflow/ACR-BUILD-SETUP.md）。"
    exit 1
  else
    warn "找不到 ${verify_script}，跳过校验"
  fi
fi
