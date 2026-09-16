# DeepSeek Harness (dsh) 容器化部署

把 dsh(DeepSeek Harness agent)打包成 Docker 镜像, 随官方 npm 版本自动更新。

> ⚠️ 本仓库不含任何内网 IP/密钥。部署时 `cp .env.example .env`, 填你的**实际局域网 IP**。

## 🚀 快速开始

> **平台要求：仅 Linux**（`network_mode: host` 依赖 Linux 语义，macOS/Windows 会静默失效，见安全章）。

```bash
cp .env.example .env     # 必填 DSH_LAN_IP (你的部署机局域网 IP)
docker compose up -d     # 启动
```
> `DSH_LAN_IP` 为强制项: 不填则 compose 拒绝启动(fail-closed)。这是**刻意为之**——缺省 loopback 会让 dsh 特权方法暴露全网(见安全章)。

## 🧱 镜像构建与上游绑定

- **上游源 = 唯一 npm 包** `@deepseek-ai/dsh`(自包含, 无需 GitHub 源码/asset)
- 版本经 build-arg 绑定 npm version, 由 CI 定时轮询 `dist-tags.latest` 自动重建:
  ```bash
  docker build --build-arg DSH_VERSION=0.1.5-rc.2 .
  ```
- 镜像 tag 直接用 npm 版本号 (如 `0.1.1-rc.2`, `latest`)
- 发布到 repo-scoped `ghcr.io/snailium/dsh-container/dsh` (跟随仓库: 公开仓库→镜像公开; 也可 Web UI 单独改成 private)

### 自动更新 (GitHub Actions)
`.github/workflows/update.yml` 定时轮询 npm `dist-tags.latest`:
- 有新版 → `docker build --build-arg DSH_VERSION=<新版本>` → 推 ghcr
- 部署机 `docker compose pull && up -d` 即升级

## 🌐 HTTPS 端口通用 env 化 (避免端口冲突)

| 环境变量 | 默认 | 说明 |
|---|---|---|
| `DSH_WEB_PORT` | 3080 | dsh web HTTP 监听端口 |
| `DSH_HTTPS_PORT` | 8443 | HTTPS(TLS relay)访问端口 |
| `DSH_LAN_IP` | **必填** | 部署机局域网 IP (证书 SAN + 受信权威)。**无默认, 缺失 compose 拒绝启动** |
| `DSH_TRUSTED_AUTHORITY` | {LAN_IP}:3080 | relay 把外部 Host 重写成的受信权威。独立可配 |
| `DSH_RELAY_BIND_LOOPBACK` | 0 | `1` 时 relay 只绑本机(配 loopback 权威用于本机专用) |

改 HTTPS 端口(避开冲突): 编辑 `.env`
```bash
echo "DSH_HTTPS_PORT=8444" >> .env
docker compose up -d
```
访问地址相应变成 `https://<你的DSH_LAN_IP>:8444`。

## 🔐 TLS 证书 (数据卷内自动管理)

**证书放在数据卷 `/dsh-home/tls/`, 不属于镜像。** 启动时 entrypoint 处理:

| 现状 | 行为 |
|---|---|
| `cert.pem`+`key.pem`+`server.pem` 齐全 | 直接复用 |
| 只有 `cert.pem`+`key.pem` (导入的旧证书) | 自动合并生成 `server.pem` |
| 全无 | 自动生成新自签证书 (含 `DSH_LAN_IP` + localhost SAN) |

### 导入现有证书
把已有 CA/自签证书拷进数据卷 tls 目录即可(重启容器生效):
```bash
cp my-cert.pem <数据卷>/tls/cert.pem
cp my-key.pem  <数据卷>/tls/key.pem
rm -f <数据卷>/tls/server.pem      # 让 entrypoint 重新合并
docker compose restart dsh
```
> 自签证书需要浏览器「继续前往」例外一次(CN+SAN=IP, Chrome 会记住)。

## 💾 数据卷映射

dsh 有三个东西要挂，缺一不可（尤其工作区）：

| 数据 | 宿主路径(.env 填) | 容器内 | 说明 |
|---|---|---|---|
| 设置/数据根 | `$DSH_DATA_DIR` | `/dsh-home` | `$DSH_HOME`: settings.yaml、profiles/cordis.patch.yml、.credentials.yaml、sessions、storages、integrations、tls |
| **工作区** ⚠️ | `$DSH_WORKSPACE_DIR` | `/workspace` | 宿主工作区目录挂到容器内固定 `/workspace`。dsh 核心的工作区由 UI 显式新建（`create<path>` 指定目录），容器内从 `/workspace` 建工作区即可。挂载解耦：换宿主路径不改容器 |
| TLS 证书 | `<$DSH_DATA_DIR>/tls` | `/dsh-home/tls` | 见上节, entrypoint 自动管理 |

> ⚠️ **工作区挂载**：本镜像固定把 `$DSH_WORKSPACE_DIR` 挂到容器内 `/workspace`，`WORKDIR=/workspace`。要用工作区就在 UI 里新建工作区、目录选容器内的 `/workspace`（或其子目录）。统一挂载的好处是宿主路径与容器内路径解耦——换宿主目录时只需改 `.env` 的 `DSH_WORKSPACE_DIR`，容器和会话路径都不用动。
>
> **关于会话与工作区**：dsh 核心会按会话 header 固化的 `cwd`(+ `realpath`) 派生工作区归属；换工作区路径会**让旧会话落到 Ungrouped**（数据不丢、UI 分组错位）。若需把旧工作区上的会话迁移到新路径，见仓库内 [session-migration.md](session-migration.md)。

配置 = bind-mount 整块 `harness-home` → 升级只换镜像, 数据永不丢。

## 🤖 自动化测试 (headless) — 推荐形态

> **这个容器化 dsh 的主要用途是自动化测试**（如 B70 每次更新后端后的 agent 测试）。生产使用建议裸机部署；容器作为**隔离测试 harness**最方便。

**核心结论：headless CLI 完全不受 dsh 0.1.2 的 access-token 影响**——headless 模式跑单任务走 CLI 独立通道，不经 web 访问层，**零 token、零认证**，天然适合自动化测试。

### 用法: DSH_MODE=headless

```bash
# 创建一个测试 DSH_HOME 卷(首次会自动 seed headless profile + 装 web 搜索插件)
mkdir -p /home/user/dsh-test-home
# settings.yaml: 声明被测 provider + 默认模型(按你的后端填)
#   例: llm-pi-ai.providers.<name> + agent-default-model 指到它(或用 --patch 覆盖)

# 跑一个 headless 单任务 (担默认 entrypoint, 非 docker run --entrypoint dsh)
docker run --rm --network host \
  -v /home/user/dsh-test-home:/dsh-home \
  -e DSH_MODE=headless -e DSH_TEST_PROFILE=headless_wsp \
  -e DSH_HOME=/dsh-home -e <API_KEY_ENV>=<key> -e HOME=/root \
  <image> --patch /dsh-home/patch.yml "你的测试任务"
# 首次启动: 自动 seed profile + pnpm 装插件 → 跑任务。之后复用卷每次跳过安装直接跑。
# headless 不需要 DSH_LAN_IP(不做网络访问), 也不起 relay/TLS。
```

- `DSH_MODE=headless` + `DSH_TEST_PROFILE`(默认模板建于 `headless_wsp`) → entrypoint 自动确保 profile + 插件就绪后 `exec dsh --profile <p> <任务>`
- 首次启动自动安装自带插件; 数据卷复用后跳过
- `--patch` 覆盖默认模型/provider(或写 DSH_HOME/settings.yaml)

### 自带插件 (npm registry 安装)

**headless 测试 profile**（模板: `docker/headless-profile/`）首次启动自动安装:

| 插件 | 版本 | 作用 |
|---|---|---|
| `@anweat/dsh-browser` | 0.1.14-alpha.2 | 浏览器服务(web-search-pro 的必需依赖, `inject: ['browser']`) |
| `dsh-web-search-pro` | 0.1.12-alpha.6 | 多引擎 web 搜索工具(web_search_pro / web_fetch_pro 等) |
| `dsh-relay` | 0.2.1 | DSH relay 插件(注入 webServer, 提供 TLS relay 前端) |
| `dsh-opencode-session` | 0.1.1 | OpenCode 会话集成 |
| `dsh-repeat-tool-breaker` | ^0.3.2 | 重复工具调用防护(语义指纹 + 滑动窗口; 忽略 description/timeoutMs 等诱饵参数; 主机别名与易变 flag 归一化; 文件操作按「位置」判定; 同一动作第 3 次才硬拦; 本机/内网地址 `localHosts` 默认 `ask`，无应答方时自动退化成 deny；量级预算（site/family/verb）默认关闭——分页/批量抓取不再被误判为重复） |
| `dsh-command-context-trim` | ^0.1.1 | 命令上下文修剪(减少 token 消耗) |

**web 模式 profile**（用户自建）首次启动自动安装:

| 插件 | 版本 | 作用 |
|---|---|---|
| `dsh-relay` | 0.2.1 | DSH relay 插件(注入 webServer, 提供 TLS relay 前端) |
| `@anweat/dsh-browser` | 0.1.14-alpha.2 | 浏览器服务(web-search-pro 的必需依赖) |
| `dsh-web-search-pro` | 0.1.12-alpha.6 | 多引擎 web 搜索工具 |

> **自动安装机制**：entrypoint 启动时扫描 `$DSH_HOME/profiles/` 下所有含 `package.json` 的 profile，
> 从 dependencies 提取包名（排除 `@deepseek-ai/dsh-*` 框架包），缺则自动 `pnpm install`。
> headless 和 web 模式共用同一套逻辑。用户只需在 profile 的 `package.json` 中声明依赖版本，首次启动自动装齐。

## 🔄 升级

```bash
cd <dsh-container 工程>
docker compose pull        # 拉新版镜像(CI 已构建推送)
docker compose up -d       # 重建容器, 数据卷原样复用
```

## 🛡️ 安全

### ⚠️ 先说清楚：全链路零认证（务必读）
**dsh 的 Web UI 和 relay 都没有登录认证。** 上游 fence 明确声明 "this fence is not an auth layer"。这意味着:
- **任何能连到 8443 的主机** 都能读取全部会话/对话内容, 并通过非特权方法**驱动 agent 执行**(agent 能读写工作区!)
- 防火墙、WARP/Mesh 访问隔离、IP 白名单是**唯一**的真实防线——不是摆设, 是必需的
- 因此**禁止**把 8443 暴露到公网/不可信网络

### 强制防护(本项目已内置)
- **fail-closed 启动校验** (审查 S1): `DSH_LAN_IP` 必填(compose 校验 + entrypoint 双重保证), 缺省 loopback 时拒绝启动——绝不把特权面(bind-mount 的配置/凭据/TLS 私钥)暴露给全网
- **非 root 运行** (审查 H1): entrypoint(以 root 启动以管理证书/chown) 用 `runuser -u node` 降权启动 dsh/relay 工作进程, 进程属主为 node(uid 1000), 无 root 权限
- **特权方法隔离**: dsh 的 `settings.*`/`credentials.*`/`host.pickDirectory`/`llm.discoverModels` 只认 loopback Host, 远程始终 403(改 Models 走配置驱动)
- image 内不烘焙任何密钥/配置; 全运行时挂卷

### 建议的防火墙(ufw 示例, 默认拒绝入向)
```bash
# 只允许本机 web 端口 + 你实际需要访问的来源
sudo ufw default deny incoming
# 本机直接用
sudo ufw allow proto tcp from 127.0.0.1 to any port 3080,8443
# 局域网/WARP 来源(按需开启, 替换成你的网段/来源)
sudo ufw allow proto tcp from 192.168.1.0/24 to any port 8443
```
> 更严格的做法: 完全不开放 8443 到 LAN, 仅通过 WARP/Mesh(Cloudflare) 访问; 或用 `DSH_RELAY_BIND_LOOPBACK=1` 只在本机用。

### 平台
- 仅 **Linux** (`network_mode: host` + relay 依赖 Linux 网络语义)。macOS/Windows Docker 的 host 网络语义不同, 会静默失效。

### 排查提示
- `settings.*` 远程 403 是**预期行为**(设计如此), 不是 bug——远程改 provider 走配置文件
- `DSH_TRUSTED_AUTHORITY` 若被你改成 entrypoint `--trusted-host` 列表外的值, 所有 LAN 流量会 403(fail-closed); 排查时先确认两者一致

## ⚠️ node 版本坑(已由镜像规避)

dsh 全局包绑定 node 版本, node20 会崩 `createZstdDecompress`。
本镜像锁定 **node:22**, 永不再踩——这是容器化的核心收益之一。