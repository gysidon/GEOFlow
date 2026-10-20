#!/usr/bin/env bash
#
# 校验 ACR 上构建出的两个镜像是否正确。
#
# 背景：ACR 内置规则锁死「Dockerfile文件名 = Dockerfile」。两个仓库监听同一 tag 时，
# 会构建出同一个 app 镜像 —— geoflow-web 镜像里没有 Nginx，web 容器起不来。
# 这个脚本在构建完成后立即发现该问题，避免部署时才暴露。
#
# 用法：
#   bash deploy-scripts/verify-acr-images.sh 3.1.0
#   REGISTRY=registry.cn-chengdu.aliyuncs.com NS=kintreda \
#     bash deploy-scripts/verify-acr-images.sh 3.1.0
#
# 退出码：0 = 两个镜像都正确；1 = 存在问题（会打印具体原因）
#
set -euo pipefail

REGISTRY="${REGISTRY:-registry.cn-chengdu.aliyuncs.com}"
NS="${NS:-kintreda}"
REPO_APP="${REPO_APP:-geoflow-app}"
REPO_WEB="${REPO_WEB:-geoflow-web}"

VERSION="${1:-}"
if [[ -z "${VERSION}" ]]; then
  echo "用法: bash $0 <版本号>   例如: bash $0 3.1.0" >&2
  exit 2
fi

APP_IMAGE="${REGISTRY}/${NS}/${REPO_APP}:${VERSION}"
WEB_IMAGE="${REGISTRY}/${NS}/${REPO_WEB}:${VERSION}"

fail_count=0
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
bad()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; fail_count=$((fail_count + 1)); }
note() { printf '\033[1;34m[note]\033[0m %s\n' "$*"; }

echo "=============================================="
echo "  ACR 镜像产物校验  版本 ${VERSION}"
echo "=============================================="
echo "  app: ${APP_IMAGE}"
echo "  web: ${WEB_IMAGE}"
echo "=============================================="
echo ""

# 私有仓库需要先登录。登录状态由调用方保证（docker login）。
pull() {
  local img="$1"
  if ! docker pull --quiet "$img" >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

# 在镜像里执行一条命令并检查输出。命令通过 sh -c 传入，避免本地 shell 干扰。
probe() {
  local img="$1" script="$2"
  docker run --rm --entrypoint sh "$img" -c "$script" 2>/dev/null
}

echo "--- 拉取镜像 ---"
if pull "${APP_IMAGE}"; then
  ok "app 镜像可拉取"
else
  bad "app 镜像拉取失败：${APP_IMAGE}"
  note "可能是构建还没完成，或私有仓库未登录（docker login --username=<用户> ${REGISTRY}）"
fi

if pull "${WEB_IMAGE}"; then
  ok "web 镜像可拉取"
else
  bad "web 镜像拉取失败：${WEB_IMAGE}"
  note "可能是构建还没完成，或私有仓库未登录"
fi

echo ""
echo "--- 检查镜像内容 ---"

if pull "${APP_IMAGE}"; then
  if probe "${APP_IMAGE}" 'which php-fpm >/dev/null 2>&1 && echo YES' | grep -q YES; then
    ok "app 镜像含 PHP-FPM"
  else
    bad "app 镜像里找不到 php-fpm，镜像内容异常"
  fi
  if probe "${APP_IMAGE}" 'ls /etc/nginx 2>/dev/null | head -1' | grep -q .; then
    bad "app 镜像里出现了 nginx，说明 app 与 web 的仓库规则可能配反了"
  fi
fi

if pull "${WEB_IMAGE}"; then
  if probe "${WEB_IMAGE}" 'ls /etc/nginx 2>/dev/null | head -1' | grep -q .; then
    ok "web 镜像含 Nginx"
  else
    bad "web 镜像里找不到 /etc/nginx —— 构建产物是 app 镜像，不是 web 镜像"
    echo ""
    note "修正方法（阿里云控制台 → 容器镜像服务 → 镜像仓库 → ${REPO_WEB} → 构建）："
    note "  路线 A：点规则行的「修改」，把「Dockerfile文件名」改成 Dockerfile.web"
    note "  路线 B：点「添加规则」，新建一条自定义规则："
    note "          类型 Tag / Branch/Tag release-v\$version / 上下文 / /"
    note "          Dockerfile文件名 Dockerfile.web / 镜像版本 \$version"
    note "  改完后必须提升版本号重新打 tag（同名 tag 不会触发重建）："
    note "          VERSION=3.1.1 bash deploy-scripts/release-tag.sh"
  fi
  if probe "${WEB_IMAGE}" 'which php-fpm >/dev/null 2>&1 && echo YES' | grep -q YES; then
    bad "web 镜像里出现了 php-fpm —— 确认构建的是根目录 Dockerfile（app）而不是 Dockerfile.web"
  fi
fi

echo ""
if [[ "${fail_count}" -gt 0 ]]; then
  printf '\033[1;31m校验未通过：%d 项问题\033[0m\n' "${fail_count}" >&2
  exit 1
fi
printf '\033[1;32m校验通过：两个镜像内容正确\033[0m\n'
