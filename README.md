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
  docker build --build-arg DSH_VERSION=0.1.1-rc.2 .
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
| **工作区** ⚠️ | `$DSH_WORKSPACE_DIR` | `/workspace` | dsh-im(Telegram) 默认工作区。容器内固定挂 `/workspace`（Dockerfile WORKDIR=/workspace → `process.cwd()`=/workspace → dsh-im 默认工作区即 /workspace），不再依赖同路径 bind |
| TLS 证书 | `<$DSH_DATA_DIR>/tls` | `/dsh-home/tls` | 见上节, entrypoint 自动管理 |

> ⚠️ **工作区挂载**：dsh-im 的 `BotWorkspaceStore` 默认工作区 = `process.cwd()`，而容器 WORKDIR 是 `/workspace`，所以首次启动的默认工作区自动是容器内 `/workspace`。用 compose 把 `$DSH_WORKSPACE_DIR` 挂到 `/workspace` 即可。
>
> **从旧版(同路径 bind)迁移**：旧部署的 `$DSH_HOME/integrations/dsh-telegram/workspaces.json` 里 Telegram 机器人的 workspace 是旧宿主绝对路径。切到 `/workspace` 挂载后，需二选一：① 删除该文件里的绑定，让默认值(process.cwd()=/workspace)接管；② 把旧工作区数据迁到新 `$DSH_WORKSPACE_DIR` 目录，并同步更新该 JSON 为 `/workspace`。不做迁移的话，旧绑定会指向容器内不存在的路径 → 会话错乱。

配置 = bind-mount 整块 `harness-home` → 升级只换镜像, 数据永不丢。

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