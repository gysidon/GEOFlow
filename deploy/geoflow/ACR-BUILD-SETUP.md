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
| 分支/标签 | `tags: release-v$version` |
| 构建上下文目录 | `/` |
| Dockerfile文件名 | `Dockerfile` |
| 镜像版本 | `$version` |

### 仓库 `geoflow-web`

| 配置项 | 填写值 |
| --- | --- |
| 分支/标签 | `tags: release-v$version` |
| 构建上下文目录 | `/` |
| Dockerfile文件名 | `Dockerfile.web` |
| 镜像版本 | `$version` |

### 规则含义

- `release-v$version` 是 ACR 内置正则。源码 tag 为 `release-v3.1.0` → 自动构建出 `3.1.0` 版本镜像。
- `$version` 是命名捕获组，镜像 tag 取 tag 中 `release-v` 之后的部分。
- **构建上下文目录必须是 `/`**：Dockerfile 里的 `COPY . .` 需要仓库根目录作为上下文。
- 配了正则后仅支持系统自动构建，控制台的「立即构建」按钮不可用。

---

## 四、发版

```bash
cd /path/to/GEOFlow
bash deploy-scripts/release-tag.sh
```

脚本会打 `release-v<版本号>` tag 并推送到 `origin`，ACR 随即开始构建。

**产出镜像**：

```
registry.cn-chengdu.aliyuncs.com/kintreda/geoflow-app:3.1.0
registry.cn-chengdu.aliyuncs.com/kintreda/geoflow-web:3.1.0
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
| 镜像 tag 与预期不符 | `$version` 捕获的是 tag 里 `release-v` 之后的部分 | 确认 tag 严格是 `release-v` + 纯数字版本号 |
| 预发布 tag 不触发构建 | `release-v3.1.0-beta1` 匹配不上 `$version` | 预发布版用纯数字版本号，或控制台手动构建 |
| 部署时 `manifest unknown` | 版本号写错或镜像没构建出来 | 核对 ACR 控制台实际产出的 tag |
| 拉镜像 401 | 私有仓库未登录 | `docker login --username=<用户名> registry.cn-chengdu.aliyuncs.com` |
