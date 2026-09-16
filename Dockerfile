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
ARG DSH_VERSION=0.1.5-rc.2
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

# headless 自动化测试: entrypoint 首次启动用 pnpm 安装测试 profile 插件。
#   pnpm 在镜像构建期 `npm i -g pnpm` 装好(避免运行时 corepack 首次下载挂起)。
#   插件从 npm registry 直接安装(官方兼容版已发布):
#   - @anweat/dsh-browser@0.1.14-alpha.2
#   - dsh-web-search-pro@0.1.12-alpha.6
#   - dsh-relay@0.2.1
#   - dsh-opencode-session@0.1.1
#   - dsh-repeat-tool-breaker@^0.3.2
#   - dsh-command-context-trim@^0.1.1
RUN npm i -g pnpm

# 工程内置代码层: TLS relay + entrypoint
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/dsh-tls-relay.js /usr/local/bin/dsh-tls-relay.js
# 宿主 umask 077 时 COPY 会保留 600/700 权限 → node(非root) 读不了 relay 脚本(EACCES)。
# 显式归一: entrypoint(root 执行, 可 750), relay(node 需可读, 644)。
RUN chmod 750 /usr/local/bin/entrypoint.sh && chmod 644 /usr/local/bin/dsh-tls-relay.js

# headless 自动化测试用的 profile 模板:
#   entrypoint DSH_MODE=headless 首次启动会 seed 模板到数据卷, 然后 pnpm install
#   从 npm registry 安装插件(见 package.json dependencies)。
COPY docker/headless-profile/ /opt/dsh-headless-profile/

# 安全: dsh/relay 工作进程以非 root(node/uid1000) 运行。
#   注意: 不在 Dockerfile 设 `USER node`——entrypoint 需要 root 权限生成/chown 证书
#   (已有 root 属主证书时 node 无法接管)。由 entrypoint 用 `runuser -u node` 降权
#   启动两个工作进程, 达成与 `USER node` 相同的"进程非 root"(review H1)而不破坏证书管理。
#   runuser 为非交互降权(无需 gosu)。node uid=1000 与宿主 gwang 同 uid → 能读写 bind-mount。

# 数据/证书卷(必须挂载, entrypoint 会建 tls)
# ⚠️ 裸 `docker run` 不挂卷时, 此匿名卷会"悄悄吞掉"数据(数据存进匿名卷而非宿主路径)。
#    必须用 docker compose(docker-compose.yml 显式 bind-mount) 或 docker run -v 挂载。
#    /workspace 卷同理: 不挂载时工作区数据也进匿名卷, 不会落在宿主期望路径。
VOLUME ["/dsh-home"]

# 工作区卷: 宿主 $DSH_WORKSPACE_DIR 挂载到容器内固定 /workspace。
# dsh 核心的工作区由 UI 显式 "新建工作区"(workspace.create<path>) 指定目录——没有一个
# "默认工作区=process.cwd()" 机制。统一挂 /workspace 的意义:
#   ① WORKDIR=/workspace → dsh web 启动后进程 cwd 确定且可预期(默认运行目录);
#   ② 宿主工作区目录与容器内路径解耦, 换宿主路径不用改容器。
# 在 UI 新建工作区时选容器内 /workspace(或其子目录) 即可。旧版"(dsh-im 默认工作区=
# process.cwd())"的提法不成立——dsh-im 是独立插件, 项目不带, 见 README "工作区挂载"节。
WORKDIR /workspace
VOLUME ["/workspace"]

EXPOSE 3080 8443

# 健康检查: 同时验证 web(3080) 和 TLS relay(8443)。relay 挂了直接 unhealthy (review M4)
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
  CMD curl -fsS http://127.0.0.1:${DSH_WEB_PORT}/ -o /dev/null \
    && curl -kfsS https://127.0.0.1:${DSH_HTTPS_PORT}/ -o /dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]