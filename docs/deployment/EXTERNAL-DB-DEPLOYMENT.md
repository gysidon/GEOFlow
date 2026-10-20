# GEOFlow 外部数据库部署（复用已有 PostgreSQL / Redis）

本文覆盖一种独立于标准生产编排的部署形态：**GEOFlow 应用栈仍用 Docker 跑在服务器上，但数据库和 Redis 使用服务器上（或远端）已经存在的实例，不启动 compose 内置的 `postgres` / `redis` 容器。**

配套文件：

- `docker-compose.external-db.yml`：override 编排层，移除内置数据库容器
- `.env.prod.external-db.example`：环境变量模板，数据库与 Redis 地址在此填写
- `deploy-scripts/package-source-for-server.sh`：本地打包源码用于上传

标准生产部署见 [DEPLOYMENT.md](DEPLOYMENT.md)。本文只描述与标准流程的差异部分，镜像构建、迁移门禁、升级协议等仍以 DEPLOYMENT.md 为准。

---

## 1. 方案说明

标准生产编排（`docker-compose.prod.yml`）自带 `postgres`（pgvector/pgvector:pg18）和 `redis`（redis:8-alpine）两个服务。本方案用 override 层把这两个服务摘掉，其余服务（`init` / `app` / `web` / 四个队列 / `scheduler` / `reverb`）保持不变，改为通过 `.env.prod` 里的 `DB_*` / `REDIS_*` 连接外部实例。

```text
标准部署：  compose ──> postgres 容器 + redis 容器
本方案：    compose ──> 外部 PostgreSQL 实例 + 外部 Redis 实例
```

三条约束决定了实现方式：

| 约束 | 影响 |
| --- | --- |
| 7 个服务的 `depends_on` 指向 `postgres` / `redis` | 摘除服务后必须同步清理这些引用，否则 Compose 报 `depends on undefined service` |
| 迁移需要 `CREATE EXTENSION vector` | pgvector 不是 trusted 扩展，应用账号无权创建，必须由 superuser 预先装好 |
| `cache` 连接默认使用 `REDIS_CACHE_DB=1` | Redis 集群模式不支持 `SELECT`，集群实例必须改为 db 0 |

---

## 2. 前置检查

### 2.1 目标 PostgreSQL 必须已安装 pgvector

先在目标库上确认扩展可用：

```sql
-- 用超级用户连接目标库执行
SELECT * FROM pg_available_extensions WHERE name = 'vector';
```

- **返回空**：服务器上的 PostgreSQL 没装 pgvector 二进制，需要先安装（自建实例装对应版本的 `postgresql-XX-pgvector` 包；云实例见各自厂商的扩展白名单机制）。
- **有行但 `installed_version` 为空**：扩展文件在，但没有在当前库启用，执行一次：

```sql
CREATE EXTENSION IF NOT EXISTS vector;
```

这一步必须由超级用户执行。pgvector 的 `vector.control` 未标记 `trusted`，普通角色执行会得到 `permission denied to create extension "vector"`。

装好之后，应用的迁移 `database/migrations/2026_04_18_110000_enable_pgvector_extension.php` 里的 `CREATE EXTENSION IF NOT EXISTS vector` 会退化为一条无权限要求的 NOTICE 并直接跳过，不会中断迁移。

> 若目标库无法安装 pgvector，知识库向量列 `knowledge_chunks.embedding_vector` 不会被创建（对应迁移有存在性判断，会安全跳过），但知识库向量化与相似检索功能不可用。

### 2.2 容器到数据库的网络可达性

容器运行在 `geoflow-prod-net`（默认 `10.88.0.0/16`）里，容器内的 `127.0.0.1` 指向容器自身。目标实例必须接受来自容器网段的连接。

在目标 PostgreSQL 上确认：

```sql
SHOW listen_addresses;   -- 不能只有 localhost，需包含实例的内网地址
```

并检查 `pg_hba.conf` 存在放行容器网段的规则：

```
host    geo_flow    geoflow_user    10.88.0.0/16    scram-sha-256
```

如果实例就在同一台服务器上：

- 填内网 IP 最稳妥，例如 `DB_HOST=10.0.1.20`；
- 也可用 `host.docker.internal`，`docker-compose.external-db.yml` 已通过 `extra_hosts` 把它映射到宿主机网关（Linux 上需要 Docker 20.10+）；
- 注意实例若只监听 `127.0.0.1`，容器依然连不上，必须让实例监听内网地址。

### 2.3 目标 Redis

- 有密码：填 `REDIS_PASSWORD`；无密码：留空（**不要写 `null` 字面量**）。
- **集群模式**（阿里云/腾讯云集群版、自建 cluster）：只支持 db 0，必须设 `REDIS_DB=0` 且 `REDIS_CACHE_DB=0`，否则会报 `ERR SELECT is not allowed in cluster mode`。
- 单机模式：`REDIS_DB=0`、`REDIS_CACHE_DB=1` 即可，两者用不同逻辑库隔离。

### 2.4 服务器环境

- Docker Engine 20.10+ 与 Docker Compose **v2.24.4+**（override 用到 `!reset` / `!override` 标签，低于该版本会解析失败）。
- 建议 2 核 4 GB 内存起，磁盘 40 GB 以上。

```bash
docker --version
docker compose version
```

---

## 3. 打包与上传

在本地项目根目录执行：

```bash
bash deploy-scripts/package-source-for-server.sh
```

脚本在 `dist/` 生成 `geoflow-source-<时间戳>.tar.gz`（约 15 MB），已排除 `vendor` / `node_modules` / `.git` / `tests` / 本地 `.env` 等在服务器上会重新生成的内容，同时保留 `storage/` 目录骨架。

上传：

```bash
scp dist/geoflow-source-<时间戳>.tar.gz user@your-server:/opt/
```

服务器上解包：

```bash
cd /opt
tar -xzf geoflow-source-<时间戳>.tar.gz
cd geoflow
```

> 用 `tar` 解包即可，不需要 git。若要保留版本历史，改用 `git clone` 拉仓库并单独执行上述打包步骤的排除逻辑。

---

## 4. 配置环境变量

```bash
cp .env.prod.external-db.example .env.prod
vi .env.prod
```

必须修改的项：

| 变量 | 说明 |
| --- | --- |
| `DB_HOST` | 目标 PostgreSQL 地址 |
| `DB_PORT` | 默认 `5432` |
| `DB_DATABASE` | 业务库名，默认 `geo_flow` |
| `DB_USERNAME` / `DB_PASSWORD` | 连接账号 |
| `DB_SSLMODE` | 云托管实例通常为 `require`；自建内网用 `prefer` |
| `REDIS_HOST` | 目标 Redis 地址 |
| `REDIS_PORT` | 默认 `6379` |
| `REDIS_PASSWORD` | 无密码留空 |
| `REDIS_DB` / `REDIS_CACHE_DB` | 集群模式均为 `0` |

同时确认这几项与实际情况一致：

- `APP_URL` / `REVERB_HOST` / `REVERB_ALLOWED_ORIGINS`：填真实对外域名。
- `SESSION_SECURE_COOKIE`：HTTPS 用 `true`，直接用 `http://IP:端口` 访问用 `false`，否则浏览器不回传登录 Cookie。
- `TRUSTED_PROXIES`：走反向代理、CDN 或负载均衡时填实际代理 IP/CIDR，避免写 `*`。
- `WEB_PORT`：对外端口，默认 `18080`。
- `APP_KEY`：留空即可，init 容器启动时会 `key:generate` 写回本文件。
- `GEOFLOW_APP_IMAGE` / `GEOFLOW_WEB_IMAGE`：服务器本地构建时保持 `geoflow-app-prod:latest` / `geoflow-web-prod:latest`；若改为拉取预构建镜像，换成仓库里的实际地址。

---

## 5. 构建镜像

服务器上构建（首次约 10–20 分钟，取决于服务器到镜像源的网络）：

```bash
export COMPOSE='docker compose --env-file .env.prod -f docker-compose.prod.yml -f docker-compose.external-db.yml'

$COMPOSE build
```

构建内容：

- `docker/Dockerfile.prod` → app 镜像（PHP 8.4 FPM + Composer 依赖 + 前端产物）
- `docker/nginx/Dockerfile.prod` → web 镜像（Nginx + 前端静态资源）

> 国内服务器拉取基础镜像慢时，见 DEPLOYMENT.md 第 9 节，或使用 `deploy-scripts/pull-images-once-via-tunnel.sh` 与 `build-once-via-tunnel.sh` 走隧道代理。

> 实际耗时参考：4 核服务器上完整构建（编译 mbstring / opcache / pcntl / pdo_pgsql / pdo_sqlite / zip 六个 PHP 扩展 + pecl redis + npm build）约 **25–40 分钟**。4 核机器上 opcache JIT 与 pecl redis 编译是两个最耗时的步骤。构建过程建议用后台任务 + 状态文件轮询，避免 SSH 断连导致中断：
>
> ```bash
> # 服务器上
> nohup bash -c 'sudo docker compose --env-file .env.prod \
>   -f docker-compose.prod.yml -f docker-compose.external-db.yml build \
>   > /tmp/build.log 2>&1; echo "EXIT=$?" >> /tmp/build.log' </dev/null >/dev/null 2>&1 &
>
> # 轮询
> grep -o 'EXIT=[0-9]*' /tmp/build.log
> ```
>
> **注意**：Docker 需 root 权限时，`sudo` 会要求 TTY 输入密码，导致后台任务无法自动执行。用 `echo <密码> | sudo -S -p '' docker compose ...` 传入，或在服务器上配置免密 sudo。

### 5.1 替代方案：本地构建后推仓库，服务器只拉镜像

若服务器网络受限，改为在本地构建并推送，服务器只执行 `pull`：

```bash
# 本地（Mac / Linux）
REGISTRY=registry.cn-beijing.aliyuncs.com NS=geo_flow VERSION=20261020 \
  bash deploy-scripts/build-and-push-amd64-images.sh
```

服务器端把 `.env.prod` 的镜像名换成仓库地址，并用 `docker-compose.prebuilt.yml` 替代 `docker-compose.prod.yml`：

```bash
export COMPOSE='docker compose --env-file .env.prod -f docker-compose.prebuilt.yml -f docker-compose.external-db.yml'
$COMPOSE pull
```

两个编排的 override 通用，差异只在 `build` 段是否存在。镜像架构需与服务器一致（`linux/amd64` 或 `linux/arm64`），可用 `docker buildx imagetools inspect` 确认。

---

## 6. 启动

```bash
export COMPOSE='docker compose --env-file .env.prod -f docker-compose.prod.yml -f docker-compose.external-db.yml'

# 一次性 init：执行数据库迁移与首次安装
$COMPOSE up init

# 常驻服务
$COMPOSE up -d --remove-orphans app web queue ai-quality-queue \
  ai-quality-backfill-queue ai-optimization-queue knowledge-queue scheduler reverb
```

`init` 容器启动后先通过 `pg_isready` 轮询 `DB_HOST`（`AUTO_WAIT_FOR_DB=true`），确认数据库可达后再执行迁移。这是 entrypoint 的既有机制，不需要为外部实例做改动。

查看状态：

```bash
$COMPOSE ps
$COMPOSE logs --tail=100 init
```

---

## 7. 部署后校验

```bash
# 容器状态
docker compose --env-file .env.prod -f docker-compose.prod.yml -f docker-compose.external-db.yml ps

# HTTP 健康端点
curl -fsS http://127.0.0.1:18080/up

# 数据库连通性与迁移状态（应无待执行迁移）
docker compose --env-file .env.prod -f docker-compose.prod.yml -f docker-compose.external-db.yml \
  exec -T app php artisan migrate:status --pending=1 --no-interaction
```

> 仓库自带的 `deploy-scripts/geoflow-healthcheck.sh` 会把 `postgres` 和 `redis` 列为必检服务，在本方案下会误报缺失。请用上面的命令替代，或在脚本中移除这两个服务的检查项。

### 7.1 在没有 psql 的机器上操作远程 PostgreSQL

服务器上没装 psql 时，用官方 postgres 镜像当客户端，无需在目标库装任何东西：

```bash
docker run --rm -e PGPASSWORD='<密码>' postgres:16-alpine \
  psql -h <PG地址> -p 5432 -U <账号> -d <库名> -c "SELECT 1;"
```

这条路径同时可用于：建库、启用扩展、查 `pg_available_extensions`、执行迁移前的权限预检。

访问：

- 前台：`APP_URL`
- 后台：`APP_URL/geo_admin/login`
- 默认管理员：`admin` / `password`，**首次登录后立即修改密码**

---

## 8. 常见问题

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `extension "vector" is not available` | 目标 PostgreSQL 未安装 pgvector 二进制 | 按 2.1 安装扩展包 |
| `permission denied to create extension "vector"` | 应用账号非 superuser，扩展未预先创建 | 用 superuser 执行一次 `CREATE EXTENSION IF NOT EXISTS vector;` |
| `could not translate host name` / `Connection refused` | 容器到实例网络不通 | 检查 `listen_addresses`、`pg_hba.conf`、安全组与防火墙 |
| `ERR SELECT is not allowed in cluster mode` | Redis 是集群模式但 `REDIS_CACHE_DB=1` | 两个库号都设为 `0` |
| `depends on undefined service "postgres"` | Compose 版本低于 v2.24.4，或未叠加 override 文件 | 升级 Compose；确认命令包含 `-f docker-compose.external-db.yml` |
| 容器反复重启，init 日志停在 `waiting for postgres` | `DB_HOST` 填错或实例未监听容器可达地址 | 用 `docker compose exec` 内的 `pg_isready` 手工验证连通性 |
| 队列任务不执行 | 队列连接 `redis` 不可达 | 检查 `REDIS_*` 配置与 `redis` 容器日志（本方案下由外部实例承担） |

---

## 9. 升级与回滚

外部数据库方案的升级流程与 DEPLOYMENT.md 第 3.1 节一致，唯一差异是第 4 步构建命令需要带上 override 文件：

```bash
$COMPOSE build
$COMPOSE up init
$COMPOSE up -d --remove-orphans app web queue ai-quality-queue \
  ai-quality-backfill-queue ai-optimization-queue knowledge-queue scheduler reverb
```

已有数据的实例升级时，迁移门禁要求先停机排空并临时置 `GEOFLOW_SECURITY_UPGRADE_DRAIN_CONFIRMED=true`，具体流程见 DEPLOYMENT.md 3.1 节，不要跳过。

**备份对象相应变化**：`.env.prod`、`storage/` 目录，以及外部 PostgreSQL 实例的数据（`pg_dump`）、外部 Redis 实例的数据。compose 内置的 `POSTGRES_DATA_DIR` 卷不再承担备份职责。

---

## 10. 关键差异对照

| 项目 | 标准生产部署 | 本方案 |
| --- | --- | --- |
| 编排文件 | `docker-compose.prod.yml` | `docker-compose.prod.yml` + `docker-compose.external-db.yml` |
| PostgreSQL | compose 内置 pgvector 容器 | 外部实例 |
| Redis | compose 内置 redis 容器 | 外部实例 |
| 数据卷 | `POSTGRES_DATA_DIR` 目录 | 由外部实例自行管理 |
| 迁移前置 | 容器自带 pgvector | 需 superuser 预装扩展 |
| 健康检查脚本 | `geoflow-healthcheck.sh` 可直接用 | 需去掉 postgres / redis 必检项 |
