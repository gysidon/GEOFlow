# GEOFlow 独立部署指南

本文覆盖一条完整的自建发布链路：从 GitHub fork 同步上游代码 → 构建镜像并推送到阿里云镜像仓库 → 在任意服务器用一份 `docker-compose.yml` 直接运行。

上游项目：[yaojingang/GEOFlow](https://github.com/yaojingang/GEOFlow)

---

## 1. 整体架构

```text
  上游仓库                     你的 Fork                    阿里云镜像仓库
  yaojingang/GEOFlow  ──①sync──▶  gysidon/GEOFlow  ──②tag──▶  registry.cn-chengdu
        ▲                              │                    .aliyuncs.com/kintreda
        │                              │                    ├── geoflow-app
        └──────────────────────────────┘                    └── geoflow-web
                                                               │
                                                               │③pull
                                                               ▼
                                                      目标服务器（任意）
                                                      deploy/geoflow/
                                                      ├── docker-compose.yml
                                                      ├── .env
                                                      └── storage/
```

三个环节：

| 环节 | 动作 | 工具 |
| --- | --- | --- |
| ① 同步上游 | 拉取上游并合并到你的分支 | `deploy-scripts/fork-sync-upstream.sh` |
| ② 构建镜像 | 打 `release-v$version` tag，ACR 自动构建 | `deploy-scripts/release-tag.sh`（或 ACR 控制台手动构建） |
| ③ 部署运行 | 拉镜像 + 起服务 | `deploy/geoflow/docker-compose.yml` |

---

## 2. 首次准备（一次性）

### 2.1 建立 Git 仓库与双远端

```bash
cd /path/to/GEOFlow
git init
git remote add origin   git@github.com:gysidon/GEOFlow.git
git remote add upstream git@github.com:yaojingang/GEOFlow.git
git fetch upstream --tags
git checkout -b custom upstream/main
```

`upstream` 用于拉取上游更新，`origin` 是你自己的 fork。

### 2.2 创建阿里云镜像仓库

登录 [阿里云容器镜像服务控制台](https://cr.console.aliyun.com/)，选择 **成都（cn-chengdu）** 地域：

1. 创建命名空间 `kintreda`（若已存在则跳过）
2. 在命名空间下创建两个镜像仓库：
   - `geoflow-app`
   - `geoflow-web`
3. 记录仓库类型：**个人版**（`registry.cn-chengdu.aliyuncs.com`）或**企业版**（`registry.cn-chengdu.cr.aliyuncs.com`）。本文档按个人版写，企业版需替换地址。

> **为什么是两个仓库**：ACR 的构建规则是「一个镜像仓库 → 一条规则 → 一个镜像」。
> GEOFlow 需要 app（PHP-FPM + 业务代码）和 web（Nginx + 前端静态资源）两个镜像，
> 因此必须建两个仓库，各自配一条构建规则。
>
> 镜像地址格式为 `<ACR地址>/<命名空间>/<仓库名>:<版本>`，例如
> `registry.cn-chengdu.aliyuncs.com/kintreda/geoflow-app:3.1.0`。

### 2.3 绑定代码源（ACR 自动构建的前提）

ACR 要从 GitHub 拉代码，必须先绑定代码源：

1. 控制台 → **仓库管理 → 代码源** → 找到 **GitHub** → 点击「绑定账号」
2. 跳转到 GitHub 授权页，登录后点击 **Authorize AliyunDeveloper**
3. 返回 ACR 控制台，GitHub 一行显示「已绑定」即成功

> 个人版实例只支持绑定 **GitHub 个人版账号**（OAuth 授权）。
> 绑定后 ACR 才能读取你 fork 仓库的代码与 tag。

### 2.4 配置两个仓库的构建规则

**ACR 个人版不提供代码源构建的公开 API，规则只能在控制台配置。** 两个仓库各配一条：

#### 仓库 `geoflow-app`

进入仓库详情 → 左侧 **构建** → **添加规则**：

| 配置项 | 填写值 |
| --- | --- |
| 分支/标签 | `tags: release-v$version` |
| 构建上下文目录 | `/` |
| Dockerfile文件名 | `Dockerfile` |
| 镜像版本 | `$version` |

#### 仓库 `geoflow-web`

| 配置项 | 填写值 |
| --- | --- |
| 分支/标签 | `tags: release-v$version` |
| 构建上下文目录 | `/` |
| Dockerfile文件名 | `Dockerfile.web` |
| 镜像版本 | `$version` |

**规则说明**：

- `release-v$version` 是 ACR 的**内置正则规则**。源码 tag 为 `release-v3.1.0` 时，
  ACR 自动构建出版本号为 `3.1.0` 的镜像。
- `$version` 是命名捕获组，镜像 tag 直接取 tag 里 `release-v` 之后的部分。
- **构建上下文目录必须是 `/`**：Dockerfile 里的 `COPY . .` 需要仓库根目录作为上下文。
  根目录的 `Dockerfile` / `Dockerfile.web` 就是为此准备的入口文件。
- 设置了正则规则后**仅支持系统自动构建**，不支持控制台的「立即构建」按钮——
  想重新构建就换个版本号重新打 tag。

> **关于两个入口 Dockerfile**：上游的 `docker/Dockerfile.prod` 与
> `docker/nginx/Dockerfile.prod` 使用了 `RUN --mount=type=cache`（BuildKit 专属语法）。
> ACR 的托管构建器不保证开启 BuildKit，保留会直接报 `unknown flag: mount` 导致构建失败。
> 根目录的 `Dockerfile` 已去掉该语法，其余内容与上游一致。
> 上游文件保持原样，供服务器本地构建与 GitHub Actions 使用。

### 2.5 配置 ACR 访问凭证

在控制台「实例列表 → 访问凭证」页面设置**固定密码**：

- 长度 8–32 位，至少包含字母/符号/数字中的两类
- **不能包含 `$` 符号**
- 避免使用 `@` 等特殊字符，否则 `docker login` 可能因 shell 转义失败

记录下 `docker login` 命令中的用户名。若是 RAM 用户，格式为 `用户名@账号ID.onaliyun.com`。

> ACR 自动构建推送到自己的仓库**不需要**额外配置；
> 这个凭证是给**部署服务器拉取私有镜像**用的。

### 2.6 配置 GitHub Secrets（可选：启用 GitHub Actions 备用链路）

ACR 内置规则已能覆盖日常发布。以下配置是**可选**的——如果你需要多架构
（同时支持 amd64 与 arm64）或想在 GitHub 上看构建日志，再启用它。

进入你的 fork 仓库 → **Settings → Secrets and variables → Actions → New repository secret**：

| Secret | 值 |
| --- | --- |
| `ACR_USERNAME` | ACR 访问凭证页显示的用户名 |
| `ACR_PASSWORD` | 刚设置的固定密码 |

---

## 3. 日常开发与发布

### 3.1 修改代码

```bash
git checkout custom
# ...修改代码...
git add -A
git commit -m "feat: xxx"
git push origin custom
```

推送代码**不会**触发构建——ACR 内置规则只认 `release-v$version` 格式的 tag。
日常开发推到 `custom` 分支即可，等要发版时再打 tag（见 3.2）。

### 3.2 发版：打 tag 触发 ACR 自动构建

```bash
cd /path/to/GEOFlow

# 预演（只打印不执行），确认版本号与 tag 正确
DRY_RUN=1 bash deploy-scripts/release-tag.sh

# 正式发版
bash deploy-scripts/release-tag.sh
```

脚本做的事：

1. 读 `version.json` 的 `version` 字段（或用 `VERSION=3.1.1` 覆盖）
2. 检查工作区干净、tag 不重复、根目录 Dockerfile 存在
3. 创建 tag `release-v<版本号>` 并推送到 `origin`

推送后，ACR 立即开始构建，约 10–20 分钟后产出：

```
registry.cn-chengdu.aliyuncs.com/kintreda/geoflow-app:3.1.0
registry.cn-chengdu.aliyuncs.com/kintreda/geoflow-web:3.1.0
```

**查看构建进度**：阿里云控制台 → 容器镜像服务 → 实例 → 镜像仓库 → 选中仓库 → **构建**。

> **tag 与版本号是强绑定的**：ACR 用 `release-v$version` 捕获版本号，
> 所以 tag 必须严格是 `release-v` + 纯数字版本号（如 `release-v3.1.0`）。
> `release-v3.1.0-beta1` 这样的预发布 tag **不会**被规则匹配。
> 想发预发布版，要么用纯数字版本号，要么临时在控制台手动构建。

### 3.3 手动构建镜像（不依赖 ACR 与 CI）

需要自定义 tag、多架构，或 ACR 构建失败需要重试时使用：

```bash
# 单架构
REGISTRY=registry.cn-chengdu.aliyuncs.com \
NS=kintreda \
REPO_APP=geoflow-app \
REPO_WEB=geoflow-web \
REGISTRY_USER=<ACR用户名> \
REGISTRY_PASS=<ACR密码> \
bash deploy-scripts/release-images.sh

# 多架构（同时支持 amd64 与 arm64）
PLATFORMS=linux/amd64,linux/arm64 \
REGISTRY=registry.cn-chengdu.aliyuncs.com \
NS=kintreda \
REGISTRY_USER=<ACR用户名> \
REGISTRY_PASS=<ACR密码> \
bash deploy-scripts/release-images.sh
```

版本号默认取 `version.json` 的版本 + 短 commit，例如 `3.1.0-a1b2c3d`。可用 `VERSION=` 覆盖。

> 手动构建产出的是 `geoflow-app:3.1.0-a1b2c3d` 这种带 commit 的 tag，
> 与 ACR 自动构建的纯版本号 tag 格式不同。部署时在 `.env` 里填实际存在的 tag 即可。

### 3.4 同步上游更新

```bash
# 先看看上游有什么新提交
bash deploy-scripts/fork-sync-upstream.sh --dry-run

# 确认无误后同步并推送
bash deploy-scripts/fork-sync-upstream.sh
```

脚本行为：

- 用 `git merge` 合并（不是 rebase），保持线性历史，后续同步冲突面小
- **检测到冲突会自动 `git merge --abort` 回滚并退出**，不会留下半拉倒状态
- 合并成功后推送到 `origin/custom`

同步完成后按 3.2 打 tag 即可触发构建。

---

## 4. 在目标服务器部署

### 4.1 前置条件

| 条件 | 说明 |
| --- | --- |
| Docker + Compose | Docker 20.10+，Compose **v2.24.4+** |
| 网络能访问 ACR | `registry.cn-chengdu.aliyuncs.com` |
| 外部 PostgreSQL | 已装 **pgvector** 扩展，且目标库已执行 `CREATE EXTENSION vector` |
| 外部 Redis | 从服务器网络可达 |

**pgvector 必须在部署前装好**，否则迁移会中断：

```sql
-- 用超级用户在目标库执行一次
CREATE EXTENSION IF NOT EXISTS vector;
```

**应用账号还需要对目标库 public schema 有建表权限**。若数据库是用其他账号创建的（如 `postgres`），需补一次授权：

```sql
GRANT ALL ON SCHEMA public TO <应用账号>;
ALTER SCHEMA public OWNER TO <应用账号>;
```

> 建议建库时直接指定 owner，避免这一步：
> `CREATE DATABASE geoflow ENCODING 'UTF8' TEMPLATE template0 OWNER geoflow;`

### 4.2 准备目录

```bash
sudo mkdir -p /opt/geoflow/storage
cd /opt/geoflow
# 把 deploy/geoflow/ 下的 docker-compose.yml 与 .env.example 复制到这里
```

需要放进服务器的文件只有三个：

```
/opt/geoflow/
├── docker-compose.yml   # 编排定义
├── .env                 # 配置（从 .env.example 复制后修改）
└── storage/             # 运行时数据目录（必须存在且可写）
```

`storage/` 目录必须预先创建并保持可写，容器会往里写上传文件、缓存、日志。

### 4.3 填写配置

```bash
cp .env.example .env
vi .env
```

**必须修改的项**（模板里都是占位符）：

| 变量 | 说明 |
| --- | --- |
| `DB_HOST` / `DB_DATABASE` / `DB_USERNAME` / `DB_PASSWORD` | PostgreSQL 连接信息 |
| `DB_SSLMODE` | 自建内网用 `prefer`；云托管实例通常用 `require` |
| `REDIS_HOST` / `REDIS_PASSWORD` | Redis 连接信息 |
| `REDIS_DB` / `REDIS_CACHE_DB` | 逻辑库号；**Redis 集群模式只能为 0** |
| `APP_URL` | 站点对外地址 |
| `GEOFLOW_NGINX_PRIMARY_HOST` | Nginx 匹配的访问域名 |
| `GEOFLOW_PRIMARY_HOSTS` | **站点白名单，必须与上面一致**（见下方说明） |
| `REVERB_HOST` / `REVERB_ALLOWED_ORIGINS` | WebSocket 域名 |
| `REVERB_APP_KEY` / `REVERB_APP_SECRET` | 随机值 |
| `APP_KEY` | 应用加密密钥，见下方说明 |
| `GEOFLOW_SECURITY_FRESH_INSTALL_CONFIRMED` | 首次安装保持 `true`，装完改回 `false` |

> **两个域名变量必须一起改**：`GEOFLOW_NGINX_PRIMARY_HOST` 决定 Nginx 匹配哪个 `server_name`，
> `GEOFLOW_PRIMARY_HOSTS` 决定 Laravel 是否放行该 Host。只改前者会得到**全站 404**
> （`ResolveCurrentSite` 中间件判定失败）；只改后者则请求命中 Nginx 的 `default_server`
> 返回 **444**，表现为「Empty reply from server」。

**关于 `APP_KEY`**：留空时由容器启动时自动生成，但要求容器能写入 `.env` 文件。部分环境下 `.env` 以单文件方式挂载，容器内无法写入，生成会失败。此时预先填入：

```bash
docker run --rm --entrypoint sh <GEOFLOW_APP_IMAGE> -c 'head -c 32 /dev/urandom | base64'
# 输出写成 APP_KEY=base64:<输出内容>
```

### 4.4 拉取镜像并启动

```bash
cd /opt/geoflow

# 私有仓库需先登录（每台机器一次）
docker login --username=<ACR用户名> registry.cn-chengdu.aliyuncs.com

# 拉取镜像
docker compose --env-file .env pull

# 一次性初始化：等待数据库 → 迁移 → 首次安装 → 缓存配置
docker compose --env-file .env up init

# 启动常驻服务
docker compose --env-file .env up -d app web queue ai-quality-queue \
  ai-quality-backfill-queue ai-optimization-queue knowledge-queue scheduler reverb
```

### 4.5 验证

```bash
# 容器状态
docker compose --env-file .env ps

# HTTP 健康检查（Host 头必须与 GEOFLOW_NGINX_PRIMARY_HOST 一致）
curl -H "Host: your-domain.com" http://127.0.0.1:18080/up

# 迁移状态（应无待执行迁移）
docker compose --env-file .env exec -T app php artisan migrate:status --pending=1
```

> **首次启动会有约 30–60 秒返回 502**：app 容器的 entrypoint 会先执行 `php artisan optimize`
> （编译配置与视图缓存），完成后 PHP-FPM 才监听 9000。这期间 web 容器反代到 app 会得到 502。
> 等待容器状态变为 `healthy` 后再验证。**这不是故障。**

访问 `http://<服务器IP>:18080`，后台路径 `/geo_admin/login`。

首次安装的默认管理员：`admin`，密码为随机一次性密码，**打印在 init 容器日志里**：

```bash
docker compose --env-file .env logs init | grep -A2 'default admin'
```

也可以在 `.env` 里设 `GEOFLOW_ADMIN_PASSWORD` 预先指定。**首次登录后必须立即修改密码。**

### 4.6 安装完成后

1. 把 `.env` 里的 `GEOFLOW_SECURITY_FRESH_INSTALL_CONFIRMED` 改回 `false`
2. 登录后台修改管理员密码
3. 确认 Redis 队列在消费：

```bash
redis-cli -h <REDIS_HOST> -n <REDIS_DB> DBSIZE   # 队列库应有 key 且数量在变
```

---

## 5. 升级流程

有新版本时：

```bash
# 1. 同步上游并推送
cd /path/to/GEOFlow
bash deploy-scripts/fork-sync-upstream.sh

# 2. 打 tag 触发 ACR 构建（等约 10–20 分钟）
bash deploy-scripts/release-tag.sh

# 3. 目标服务器更新 .env 中的镜像版本
cd /opt/geoflow
vi .env
#   GEOFLOW_APP_IMAGE=registry.cn-chengdu.aliyuncs.com/kintreda/geoflow-app:<新版本>
#   GEOFLOW_WEB_IMAGE=registry.cn-chengdu.aliyuncs.com/kintreda/geoflow-web:<新版本>

# 4. 拉取新镜像
docker compose --env-file .env pull

# 5. 进入维护模式，停止旧进程
docker compose --env-file .env exec -T app php artisan down --retry=60 --refresh=15
docker compose --env-file .env stop web app queue ai-quality-queue \
  ai-quality-backfill-queue ai-optimization-queue knowledge-queue scheduler reverb

# 6. 执行迁移
docker compose --env-file .env up init

# 7. 启动新版本
docker compose --env-file .env up -d app web queue ai-quality-queue \
  ai-quality-backfill-queue ai-optimization-queue knowledge-queue scheduler reverb

# 8. 退出维护模式
docker compose --env-file .env exec -T app php artisan up
```

**回滚**：把 `.env` 里的镜像版本改回旧版本号，重新 `pull` + `up -d` 即可。数据库迁移不可自动回滚，回滚前需确认新版本迁移是否向后兼容。

---

## 6. 常见问题

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `extension "vector" is not available` | 目标 PG 未装 pgvector | 装扩展并执行 `CREATE EXTENSION vector;` |
| `permission denied to create extension "vector"` | 扩展未预建且账号非 superuser | 用 superuser 预先建好扩展 |
| `permission denied for schema public` | 应用账号对 public schema 无建表权限 | `GRANT ALL ON SCHEMA public TO <账号>;` |
| `Security upgrade blocked before schema changes` | 安全门禁未放行 | 首次安装设 `GEOFLOW_SECURITY_FRESH_INSTALL_CONFIRMED=true`；升级场景见第 5 节排空流程 |
| `ERR SELECT is not allowed in cluster mode` | Redis 是集群模式但库号非 0 | `REDIS_DB=0` 且 `REDIS_CACHE_DB=0` |
| `Empty reply from server` | 请求 Host 与 `GEOFLOW_NGINX_PRIMARY_HOST` 不匹配，命中 `default_server` 的 `return 444` | 改 Host 头或改该变量后重建 web 容器 |
| 全站 404 | `GEOFLOW_PRIMARY_HOSTS` 未包含实际访问域名 | 两个域名变量一起改，然后 `optimize:clear` + 重建 app 容器 |
| 启动初期 502 | app 的 entrypoint 正在跑 `php artisan optimize`，FPM 尚未监听 | 等容器变 healthy，通常 30–60 秒 |
| `key:generate` 报 Permission denied | 容器无法写入单文件挂载的 `.env` | 预先填好 `APP_KEY`（见 4.3） |
| `docker compose config` 报标签语法错 | Compose 版本低于 2.24.4 | 升级 Docker Compose |
| `failed to create network: Pool overlaps` | `DOCKER_NETWORK_SUBNET` 与服务器已有 Docker 网络重叠 | 换一个不冲突的网段，如 `10.99.0.0/16` |
| 拉镜像超时 | 服务器网络限制 | 配置镜像加速器，或用 `deploy-scripts/sync-images-from-local.sh` 经 SSH 灌入 |
| 队列任务不执行 | Redis 不可达或库号冲突 | 检查 `REDIS_*` 配置；`redis-cli -n <库号> DBSIZE` 看 key 数量 |

---

## 7. 文件清单

| 文件 | 用途 |
| --- | --- |
| `deploy/geoflow/docker-compose.yml` | 部署编排（自包含单文件，从 ACR 拉镜像，用外部 DB/Redis） |
| `deploy/geoflow/.env.example` | 配置模板 |
| `deploy/geoflow/README.md` | 本文 |
| `Dockerfile` | **app 镜像的 ACR 构建入口**（去 BuildKit 语法，classic builder 可构建） |
| `Dockerfile.web` | **web 镜像的 ACR 构建入口** |
| `deploy-scripts/release-tag.sh` | 打 `release-v$version` tag 触发 ACR 自动构建 |
| `deploy-scripts/fork-sync-upstream.sh` | 同步上游到 fork 分支 |
| `deploy-scripts/release-images.sh` | 手动构建并推送镜像（支持多架构） |
| `.github/workflows/release-images.yml` | 可选的 GitHub Actions 构建链路（多架构时用） |
| `deploy-scripts/package-source-for-server.sh` | 打包源码（需要连同源码部署时用） |
| `docs/deployment/EXTERNAL-DB-DEPLOYMENT.md` | 外部数据库部署详解（含踩坑记录） |

---

## 8. 与上游的关系

本目录是 fork 的自有内容，`upstream` 保持只读用途：

- 同步上游用 `git merge upstream/main`，冲突由脚本检测并回滚
- 自有改动集中在 `deploy/`、`deploy-scripts/release-images.sh`、`deploy-scripts/fork-sync-upstream.sh`、`.github/workflows/release-images.yml`
- 上游若新增同名文件，合并时需人工确认保留哪一方
