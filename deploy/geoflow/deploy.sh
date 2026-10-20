#!/bin/bash
# GEOFlow 部署：从阿里云 ACR 拉镜像启动
# 用法：bash deploy.sh [版本号]   不带版本号则用 .env 里已有的版本
set -e
cd /home/gysidon/app/geoflow

D() { echo scf198523 | sudo -S -p '' "$@"; }

VERSION="${1:-}"
if [ -n "$VERSION" ]; then
  echo ">>> 切换镜像版本到 $VERSION"
  sed -i "s|geoflow-app:[0-9.]*|geoflow-app:${VERSION}|; s|geoflow-web:[0-9.]*|geoflow-web:${VERSION}|" .env
  grep -E '^GEOFLOW_(APP|WEB)_IMAGE=' .env
fi

echo ""
echo "=== STEP 1: 拉取镜像 ==="
D docker compose --env-file .env pull

echo ""
echo "=== STEP 2: 初始化（等待数据库 → 迁移 → 缓存配置）==="
D docker compose --env-file .env up init

echo ""
echo "=== STEP 3: 启动常驻服务 ==="
D docker compose --env-file .env up -d app web queue ai-quality-queue \
  ai-quality-backfill-queue ai-optimization-queue knowledge-queue scheduler reverb

echo ""
echo "=== STEP 4: 等待就绪（entrypoint 会先跑 php artisan optimize，约 30-60 秒）==="
for i in $(seq 1 30); do
  sleep 10
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H 'Host: 10.10.10.100' http://127.0.0.1:18080/up 2>/dev/null)
  if [ "$code" = "200" ]; then
    echo "  服务就绪（第 ${i}0 秒）"
    break
  fi
  [ $((i % 3)) -eq 0 ] && echo "  等待中... (http=$code)"
done

echo ""
echo "=== 容器状态 ==="
D docker compose --env-file .env ps

echo ""
echo "=== HTTP 验证 ==="
for p in /up / /geo_admin/login; do
  printf '  %-18s ' "$p"
  curl -s -o /dev/null -w 'http=%{http_code} size=%{size_download}\n' \
    --max-time 20 -H 'Host: 10.10.10.100' "http://127.0.0.1:18080$p"
done

echo ""
echo "=== 迁移状态 ==="
D docker exec geoflow-app php artisan migrate:status --pending=1 2>&1 | tail -3
