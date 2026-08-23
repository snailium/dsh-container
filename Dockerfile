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
# DSH_LAN_IP 默认 localhost 占位; 真实部署 IP 经 docker-compose 的 .env 注入(见 .env.example)
ENV NODE_ENV=production \
    DSH_VERSION=${DSH_VERSION} \
    DSH_HOME=/dsh-home \
    DSH_WEB_PORT=3080 \
    DSH_HTTPS_PORT=8443 \
    DSH_LAN_IP=localhost \
    DSH_TRUSTED_AUTHORITY=localhost:3080

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

# 数据/证书卷(必须挂载, entrypoint 会建 tls)
VOLUME ["/dsh-home"]
WORKDIR /dsh-home

EXPOSE 3080 8443

# 健康检查: curl 本机 web = 起来了
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD curl -fsS http://127.0.0.1:${DSH_WEB_PORT}/ -o /dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]