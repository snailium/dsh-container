# DeepSeek Harness (dsh) 容器化
# 上游源: npm registry 的 @deepseek-ai/dsh (自包含包, 无需 GitHub 源码/asset)
# 版本: DSH_VERSION build-arg 绑定 npm version, 随上游自动更新
# 数据: DSH_HOME(/dsh-home) 必须挂载, 含 settings/profiles/sessions/集成 + TLS 证书
# 构建: docker build --build-arg DSH_VERSION=<npm-version> .
#
# ⚠️ 单阶段: dsh 是全局 npm 包, bin 依赖同顶层 node_modules 下的兄弟包
#    (@deepseek-ai/dsh-app-boot 等), 分阶段 COPY 会破坏 ESM 解析。直接在最终
#    node:22 镜像里安装, 全局包+bin+symlink 原位保留最稳。

FROM node:22
ARG DSH_VERSION=0.1.1-rc.2
# DSH_LAN_IP 必须经 docker-compose 的 .env 显式提供(见 review S1: 不填则 fail-closed 拒绝启动)
ENV NODE_ENV=production \
    DSH_VERSION=${DSH_VERSION} \
    DSH_HOME=/dsh-home \
    DSH_WEB_PORT=3080 \
    DSH_HTTPS_PORT=8443 \
    DSH_LAN_IP= \
    DSH_TRUSTED_AUTHORITY=

# 健康检查 + TLS 工具
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl openssl \
 && rm -rf /var/lib/apt/lists/*

# 唯一上游依赖: npm 包 (node:22 镜像锁定 node22, 永不踩 createZstdDecompress 坑)
RUN npm i -g @deepseek-ai/dsh@${DSH_VERSION}

# 工程内置代码层: TLS relay + entrypoint
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/dsh-tls-relay.js /usr/local/bin/dsh-tls-relay.js
RUN chmod +x /usr/local/bin/entrypoint.sh

# 安全: dsh/relay 工作进程以非 root(node/uid1000) 运行。
#   注意: 不在 Dockerfile 设 `USER node`——entrypoint 需要 root 权限生成/chown 证书
#   (已有 root 属主证书时 node 无法接管)。由 entrypoint 用 `runuser -u node` 降权
#   启动两个工作进程, 达成与 `USER node` 相同的"进程非 root"(review H1)而不破坏证书管理。
#   runuser 为非交互降权(无需 gosu)。node uid=1000 与宿主 gwang 同 uid → 能读写 bind-mount。

# 数据/证书卷(必须挂载, entrypoint 会建 tls)
# ⚠️ 裸 `docker run` 不挂卷时, 此匿名卷会"悄悄吞掉"数据(数据存进匿名卷而非宿主路径)。
#    必须用 docker compose(docker-compose.yml 显式 bind-mount) 或 docker run -v 挂载。
VOLUME ["/dsh-home"]

# 工作区卷(Telegram 机器人默认工作区, 见下)。dsh-im 的 bot-workspace-store 默认工作区 =
# process.cwd(), 因此把 WORKDIR 设为 /workspace 即让首次启动的默认工作区统一到 /workspace,
# 不再依赖宿主同路径 bind。旧绑定在 $DSH_HOME/integrations/dsh-telegram/workspaces.json,
# 迁移到新工作区需同步更新该文件或删除其绑定让默认值接管。
WORKDIR /workspace
VOLUME ["/workspace"]

EXPOSE 3080 8443

# 健康检查: 同时验证 web(3080) 和 TLS relay(8443)。relay 挂了直接 unhealthy (review M4)
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
  CMD curl -fsS http://127.0.0.1:${DSH_WEB_PORT}/ -o /dev/null \
    && curl -kfsS https://127.0.0.1:${DSH_HTTPS_PORT}/ -o /dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]