#!/usr/bin/env bash
#
# 打包 GEOFlow 源码用于上传到服务器本地构建镜像。
#
# 与 .dockerignore 的关系：
#   Docker 构建上下文已由 .dockerignore 排除 vendor/node_modules/.git/storage 等；
#   本脚本额外排除这些大目录，减小传输体积，同时保留 storage 目录骨架
#   （容器启动时 entrypoint 会 chown 并创建子目录，空目录结构不能丢）。
#
# 用法：
#   bash deploy-scripts/package-source-for-server.sh
#   OUTPUT_DIR=~/Desktop bash deploy-scripts/package-source-for-server.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-${PROJECT_DIR}/dist}"
PACKAGE_NAME="${PACKAGE_NAME:-geoflow-source-$(date +%Y%m%d%H%M%S)}"
ARCHIVE="${OUTPUT_DIR}/${PACKAGE_NAME}.tar.gz"

cd "${PROJECT_DIR}"

if [[ ! -f "docker/Dockerfile.prod" ]]; then
  echo "错误：未找到 docker/Dockerfile.prod，请在项目根目录执行。" >&2
  exit 1
fi

mkdir -p "${OUTPUT_DIR}"

echo ">>> 打包源码: ${PROJECT_DIR} -> ${ARCHIVE}"

# macOS 的 tar 会写入 AppleDouble 伴生文件（._*），在 Linux 上解包后会散落成垃圾文件。
# COPYFILE_DISABLE=1 关闭该行为，--exclude 同时兜底。
export COPYFILE_DISABLE=1
export COPYFILE_DISABLE_RECURSIVE=1

# --exclude 列表与 .dockerignore 对齐，额外排除本地构建产物与运行时数据。
# storage 用 --exclude 精确排空内容但保留目录骨架（靠 .gitignore 占位文件）。
tar \
  --exclude='._*' \
  --exclude='.DS_Store' \
  --exclude='./.git' \
  --exclude='./.github' \
  --exclude='./.agents' \
  --exclude='./.claude' \
  --exclude='./.codex' \
  --exclude='./.cursor' \
  --exclude='./.gemini' \
  --exclude='./.idea' \
  --exclude='./.vscode' \
  --exclude='./vendor' \
  --exclude='./node_modules' \
  --exclude='./docker-data' \
  --exclude='./tests' \
  --exclude='./bak' \
  --exclude='./browser-extension' \
  --exclude='./public/build' \
  --exclude='./public/storage' \
  --exclude='./public/hot' \
  --exclude='./bootstrap/cache/*.php' \
  --exclude='./.env' \
  --exclude='./.env.prod' \
  --exclude='./.env.backup' \
  --exclude='./.env.production' \
  --exclude='./.DS_Store' \
  --exclude='*.log' \
  -czf "${ARCHIVE}" \
  .

# storage 目录骨架必须完整保留：各子目录下的 .gitignore 是占位文件，tar 的 --exclude 通配符
# 会连同占位文件一起排除，导致目录不再落盘。entrypoint 虽会 mkdir -p 补建大部分子目录，
# 但 storage/app/private 等目录不在补建列表内，缺失会导致运行时写入失败。
echo ">>> 校验 storage 目录骨架"
missing_dirs=()
for d in storage/app/public storage/app/private storage/framework/cache/data \
         storage/framework/sessions storage/framework/views storage/logs; do
  if ! tar -tzf "${ARCHIVE}" | grep -q "^\./${d}/"; then
    missing_dirs+=("${d}")
  fi
done
if [[ ${#missing_dirs[@]} -gt 0 ]]; then
  echo "错误：压缩包缺少 storage 目录：${missing_dirs[*]}" >&2
  exit 1
fi
echo "    storage 目录骨架完整"

echo ">>> 打包完成: ${ARCHIVE}"
echo "    体积: $(du -h "${ARCHIVE}" | cut -f1)"
echo ""
echo ">>> 上传到服务器示例:"
echo "    scp ${ARCHIVE} user@your-server:/opt/"
echo ""
echo ">>> 服务器上构建并启动:"
echo "    cd /opt && tar -xzf ${PACKAGE_NAME}.tar.gz && cd geoflow"
echo "    cp .env.prod.external-db.example .env.prod   # 然后填入你的数据库/Redis 地址"
echo "    docker compose --env-file .env.prod \\"
echo "      -f docker-compose.prod.yml \\"
echo "      -f docker-compose.external-db.yml build"
echo "    docker compose --env-file .env.prod \\"
echo "      -f docker-compose.prod.yml \\"
echo "      -f docker-compose.external-db.yml up -d"
echo ""
echo ">>> 完整步骤见 docs/deployment/EXTERNAL-DB-DEPLOYMENT.md"
