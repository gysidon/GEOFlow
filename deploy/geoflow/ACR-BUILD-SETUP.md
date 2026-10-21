# ACR 构建规则配置清单

照着这份清单在阿里云控制台操作即可触发自动构建。

## 一、前置：绑定代码源

控制台路径：**容器镜像服务 → 实例列表 → 选中成都实例 → 仓库管理 → 代码源**

| 步骤 | 操作 |
| --- | --- |
| 1 | 在 **GitHub** 一行点「绑定账号」 |
| 2 | 跳转 GitHub 授权页，登录 `gysidon` 账号 |
| 3 | 点 **Authorize AliyunDeveloper** |
| 4 | 返回 ACR，GitHub 行显示「已绑定」即成功 |

> 个人版实例只支持绑定 GitHub **个人版账号**。绑定后 ACR 才能读取你 fork 仓库的代码与 tag。

---

## 二、创建两个镜像仓库

控制台路径：**仓库管理 → 镜像仓库 → 创建镜像仓库**

| 配置项 | 仓库一 | 仓库二 |
| --- | --- | --- |
| 命名空间 | `kintreda` | `kintreda` |
| 仓库名称 | `geoflow-app` | `geoflow-web` |
| 仓库类型 | 私有（推荐）或公开 | 私有（推荐）或公开 |
| 代码源 | GitHub → `gysidon/GEOFlow` | GitHub → `gysidon/GEOFlow` |
| 自动构建 | 开启 | 开启 |

> **必须是两个仓库**：ACR 一条构建规则只产出一个镜像，
> 而 GEOFlow 需要 app（PHP-FPM + 业务代码）和 web（Nginx + 前端资源）两个镜像。

---

## 三、配置构建规则

### 仓库 `geoflow-app`

控制台路径：**镜像仓库 → geoflow-app → 左侧「构建」→ 添加规则**

| 配置项 | 填写值 |
| --- | --- |
| 分支/标签 | `tags: v$version` |
| 构建上下文目录 | `/` |
| Dockerfile文件名 | `Dockerfile` |
| 镜像版本 | `latest` |

### 仓库 `geoflow-web`

| 配置项 | 填写值 |
| --- | --- |
| 分支/标签 | `tags: v$version` |
| 构建上下文目录 | `/` |
| Dockerfile文件名 | `Dockerfile.web` |
| 镜像版本 | `latest` |

### 规则含义

- `v$version` 是**自定义规则**的触发正则，用来避开内置的 `release-v*` 规则（内置规则锁死 Dockerfile 文件名，无法产出正确的 web 镜像）。
- 源码打 `v3.1.0` 这类 tag 时触发构建；**镜像版本在控制台固定填 `latest`**（个人版自定义规则不支持 `$version` 捕获，所以产物统一是 `:latest`）。
- **构建上下文目录必须是 `/`**：Dockerfile 里的 `COPY . .` 需要仓库根目录作为上下文。
- 配了正则后仅支持系统自动构建，控制台的「立即构建」按钮不可用。

---

## 三之二、验证构建产物（重要，别跳过）

**两个仓库必须构建出不同的镜像。** 配错规则会导致两个仓库都构建 app 镜像：

- `geoflow-app` 应含 PHP-FPM（`/usr/local/sbin/php-fpm`）
- `geoflow-web` 应含 Nginx（`/etc/nginx/`）

构建完成后，在部署机上各拉一个检查：

```bash
# app 镜像：应该有 php-fpm，不该有 nginx
docker run --rm --entrypoint sh <ACR地址>/kintreda/geoflow-app:latest \
  -c 'which php-fpm; ls /etc/nginx 2>/dev/null || echo "无 nginx（正确）"'

# web 镜像：应该有 nginx，不该有 php-fpm
docker run --rm --entrypoint sh <ACR地址>/kintreda/geoflow-web:latest \
  -c 'ls /etc/nginx | head -3; which php-fpm 2>/dev/null || echo "无 php-fpm（正确）"'
```

### 如果两个仓库构建出了同一个镜像

**现象**：`geoflow-web:latest` 里能查到 `php-fpm`，且体积与 app 镜像相同（673MB 而非 70MB）。

**原因**：`geoflow-web` 仓库的构建规则「Dockerfile文件名」填的是 `Dockerfile`，
两个仓库都指向了根目录的 app Dockerfile。

**解决**：把 `geoflow-web` 仓库的规则改成指向 `Dockerfile.web`。两条路任选：

**路线 A：修改现有规则（推荐）**
镜像仓库 → geoflow-web → 构建 → 找到规则 → 操作列「修改」→ Dockerfile文件名 改为 `Dockerfile.web`。

**路线 B：添加自定义规则**
如果内置规则不可编辑（或改不了），在 geoflow-web 仓库点「添加规则」新建一条：

| 配置项 | 填写值 |
| --- | --- |
| 类型 | Tag |
| Branch/Tag | `v$version` |
| 构建上下文目录 | `/` |
| Dockerfile文件名 | `Dockerfile.web` |
| 镜像版本 | `latest` |

> 官方规则说明：「当存在代码 tag 为 1.2.3 的自定义构建规则时，以自定义构建规则为准」，
> 所以自定义规则会覆盖内置规则的行为。

**改完后必须提升版本号重新打 tag**（同名 tag 不会触发重建）：

```bash
VERSION=3.1.1 bash deploy-scripts/release-tag.sh
```

然后部署机 `.env` 里的镜像版本同步锁为 `latest`（自定义规则产物固定 `latest`）。

### 个人版构建的两个硬约束

| 约束 | 影响 |
| --- | --- |
| **构建超时 30 分钟** | app 镜像要编 6 个 PHP 扩展 + pecl redis + npm build，4 核机器本地构建约 25–40 分钟，**有超时风险** |
| **只支持 amd64** | 需要 arm64 镜像时用 `deploy-scripts/release-images.sh` 或 GitHub Actions 手动构建 |

> 30 分钟超时是个人版的限制。企业版有「灵活构建配置 / 自定义构建参数 / 多架构构建」，
> 构建时间不受此限。若频繁超时，考虑升级企业版实例。

---

## 四、发版

```bash
cd /path/to/GEOFlow
bash deploy-scripts/release-tag.sh
```

脚本会打 `v<版本号>` tag 并推送到 `origin`，ACR 随即开始构建（自定义规则触发，产物为 `:latest`）。

**产出镜像**：

```
registry.cn-chengdu.aliyuncs.com/kintreda/geoflow-app:latest
registry.cn-chengdu.aliyuncs.com/kintreda/geoflow-web:latest
```

**查看构建进度**：镜像仓库 → 选中仓库 → 左侧「构建」。

---

## 五、部署机拉取

```bash
docker login --username=<ACR用户名> registry.cn-chengdu.aliyuncs.com
docker compose --env-file .env pull
```

私有仓库每台部署机都要登录一次。公开仓库可免登录。

---

## 排错

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| tag 推送后无构建记录 | 代码源未绑定 GitHub | 回第一节检查绑定状态 |
| 构建日志报 `unknown flag: mount` | Dockerfile 用了 BuildKit 专属语法 | 用仓库根目录的 `Dockerfile`（已去掉该语法），不要直接用 `docker/Dockerfile.prod` |
| 构建日志报 `Dockerfile not found` | 构建上下文目录或 Dockerfile 文件名填错 | 上下文填 `/`，app 填 `Dockerfile`、web 填 `Dockerfile.web` |
| 镜像 tag 始终是 latest | 自定义规则镜像版本固定填了 `latest`，不随 tag 变 | 符合预期；部署机 `.env` 直接锁 `:latest` 即可 |
| 预发布 tag 不触发构建 | `v3.1.0-beta1` 匹配不上 `v$version` | 预发布版用纯数字版本号，或控制台手动构建 |
| 部署时 `manifest unknown` | 版本号写错或镜像没构建出来 | 核对 ACR 控制台实际产出的 tag |
| 拉镜像 401 | 私有仓库未登录 | `docker login --username=<用户名> registry.cn-chengdu.aliyuncs.com` |
