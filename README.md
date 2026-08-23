# DeepSeek Harness (dsh) 容器化部署

把 dsh(DeepSeek Harness agent)打包成 Docker 镜像, 随官方 npm 版本自动更新。

> ⚠️ 本仓库不含任何内网 IP/密钥。部署时 `cp .env.example .env`, 填你的**实际局域网 IP**。

## 🚀 快速开始

```bash
cp .env.example .env     # 填你的 DSH_LAN_IP 等实际值
docker compose up -d     # 启动
```

## 🧱 镜像构建与上游绑定

- **上游源 = 唯一 npm 包** `@deepseek-ai/dsh`(自包含, 无需 GitHub 源码/asset)
- 版本经 build-arg 绑定 npm version, 由 CI 定时轮询 `dist-tags.latest` 自动重建:
  ```bash
  docker build --build-arg DSH_VERSION=0.1.1-rc.2 .
  ```
- 镜像 tag 直接用 npm 版本号 (如 `0.1.1-rc.2`, `latest`)
- 发布到 `ghcr.io/snailium/dsh` (私有)

### 自动更新 (GitHub Actions)
`.github/workflows/update.yml` 定时轮询 npm `dist-tags.latest`:
- 有新版 → `docker build --build-arg DSH_VERSION=<新版本>` → 推 ghcr
- 部署机 `docker compose pull && up -d` 即升级

## 🌐 HTTPS 端口通用 env 化 (避免端口冲突)

| 环境变量 | 默认 | 说明 |
|---|---|---|
| `DSH_WEB_PORT` | 3080 | dsh web HTTP 监听端口 |
| `DSH_HTTPS_PORT` | 8443 | HTTPS(TLS relay)访问端口 |
| `DSH_LAN_IP` | localhost | 证书 SAN + trusted-host 用的局域网 IP (**在 .env 填实际值**) |
| `DSH_TRUSTED_AUTHORITY` | {LAN_IP}:3080 | relay 把外部 Host 重写成的受信权威 |

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

| 数据 | 宿主路径(挂载) | 容器内 | 说明 |
|---|---|---|---|
| 设置/配置 | `harness-home` | `/dsh-home` | settings.yaml、profiles/cordis.patch.yml、.credentials.yaml |
| dsh-im | `.../integrations` | `/dsh-home/integrations` | Telegram bot 状态/token |
| 会话 | `.../sessions` | `/dsh-home/sessions` | 对话历史 |
| 运行时状态 | `.../storages` | `/dsh-home/storages` | |
| **证书** | `.../tls` | `/dsh-home/tls` | 见上节, 自动管理 |
| 日志 | 宿主 stdout | — | `docker logs dsh` |

配置 = bind-mount 整块 `harness-home` → **升级只换镜像, 数据永不丢**。

## 🔄 升级

```bash
cd <dsh-container 工程>
docker compose pull        # 拉新版镜像(CI 已构建推送)
docker compose up -d       # 重建容器, 数据卷原样复用
```

## 🛡️ 安全

- 数据面 loopback-only settings 边界保留在容器内(远程仍 403, 需配置驱动改 Models)
- 不暴露额外端口(host 网络); 远程走 WARP/Mesh 访问 HTTPS
- 镜像内不烘焙任何密钥/配置; 全部运行时挂卷
- ⚠️ dsh 是 agent(能读写工作区), Web UI 无登录认证 → 别裸暴露公网

## ⚠️ node 版本坑(已由镜像规避)

dsh 全局包绑定 node 版本, node20 会崩 `createZstdDecompress`。
本镜像锁定 **node:22**, 永不再踩——这是容器化的核心收益之一。