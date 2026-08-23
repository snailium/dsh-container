#!/bin/bash
# =============================================================================
# dsh container entrypoint
#   - TLS 证书管理: 数据卷无证书则自动生成; 有则复用(支持导入旧证书)
#   - 启动 dsh web + TLS relay 双进程, 任一挂掉自动重启
#   - HTTPS 端口/受信权威可经环境变量配置 (避免端口冲突)
# =============================================================================
set -euo pipefail

DSH_HOME="${DSH_HOME:-/dsh-home}"
DSH_WEB_PORT="${DSH_WEB_PORT:-3080}"
DSH_HTTPS_PORT="${DSH_HTTPS_PORT:-8443}"
DSH_LAN_IP="${DSH_LAN_IP:-localhost}"
DSH_TRUSTED_AUTHORITY="${DSH_TRUSTED_AUTHORITY:-${DSH_LAN_IP}:3080}"

# 默认 agent provider envs (llama.cpp/vLLM 端点不校验 key 值, 但 dsh 依此做凭据存在性检查)
export OLLAMA_API_KEY="${OLLAMA_API_KEY:-ollama-local}"
export B70_API_KEY="${B70_API_KEY:-local-b70}"

mkdir -p "$DSH_HOME"

TLS_DIR="$DSH_HOME/tls"
CERT_PEM="$TLS_DIR/cert.pem"
KEY_PEM="$TLS_DIR/key.pem"
SERVER_PEM="$TLS_DIR/server.pem"   # relay 需要 cert+key 合并

log()  { echo "[entrypoint] $*"; }

# ---------------------------------------------------------------------------
# 1) TLS 证书准备
#    规则:
#      - 三者齐全 (cert.pem + key.pem + server.pem)  -> 复用 (既有已导入的旧证书)
#      - 只有 cert.pem + key.pem, 无 server.pem       -> 由前两者合并生成 server.pem
#      - 全无                                     -> 自动生成新自签证书 (含 LAN IP + localhost SAN)
# ---------------------------------------------------------------------------
generate_cert_linux() {
  # 自签证书含 IP + localhost SAN (dsh GUI 是 SecureContext: 需 HTTPS + 受信 SAN)
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$KEY_PEM" -out "$CERT_PEM" -days 825 \
    -subj "/CN=dsh-gui" \
    -addext "subjectAltName=IP:${DSH_LAN_IP},DNS:localhost"
  # 合并为 relay 用的 server.pem (cert 在前 key 在后)
  cat "$CERT_PEM" "$KEY_PEM" > "$SERVER_PEM"
  log "🔐 已自动生成新自签证书 → $TLS_DIR (SAN: IP=${DSH_LAN_IP}, DNS:localhost)"
}

mkdir -p "$TLS_DIR"
if [ -f "$CERT_PEM" ] && [ -f "$KEY_PEM" ] && [ -f "$SERVER_PEM" ]; then
  log "✔ 复用现有证书 (cert/key/server.pem 齐全): $TLS_DIR"
elif [ -f "$CERT_PEM" ] && [ -f "$KEY_PEM" ]; then
  log "✔ 发现导入的 cert.pem+key.pem, 合并生成 server.pem ..."
  cat "$CERT_PEM" "$KEY_PEM" > "$SERVER_PEM"
  log "   server.pem 已生成"
else
  log "⚠ 无证书, 自动生成新自签证书 ..."
  generate_cert_linux
fi
chmod 600 "$KEY_PEM" "$SERVER_PEM" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 2) 启动 TLS relay + dsh web 双进程, 互相看护
# ---------------------------------------------------------------------------
log "启动 TLS relay  https://0.0.0.0:${DSH_HTTPS_PORT} -> http://127.0.0.1:${DSH_WEB_PORT} (trusted-as ${DSH_TRUSTED_AUTHORITY})"
node /usr/local/bin/dsh-tls-relay.js \
  0.0.0.0 "$DSH_HTTPS_PORT" "$SERVER_PEM" \
  127.0.0.1 "$DSH_WEB_PORT" "$DSH_TRUSTED_AUTHORITY" &
RELAY_PID=$!

log "启动 dsh web  http://127.0.0.1:${DSH_WEB_PORT}  (provider 默认经 DSH_HOME settings)"
DSH_HOME="$DSH_HOME" dsh web \
  --no-open \
  --host 127.0.0.1 \
  --port "$DSH_WEB_PORT" \
  --trusted-host "${DSH_LAN_IP}:${DSH_HTTPS_PORT}" \
  --trusted-host "${DSH_LAN_IP}:${DSH_WEB_PORT}" \
  --trusted-host "127.0.0.1:${DSH_WEB_PORT}" &
DSH_PID=$!

# 信号处理: 任一挂掉重启 (看护循环)
trap 'log "收到信号, 退出"; kill $RELAY_PID $DSH_PID 2>/dev/null; exit 0' TERM INT
while true; do
  if ! kill -0 $DSH_PID 2>/dev/null; then
    log "⚠ dsh web 挂了, 重启 ..."
    DSH_HOME="$DSH_HOME" dsh web \
      --no-open --host 127.0.0.1 --port "$DSH_WEB_PORT" \
      --trusted-host "${DSH_LAN_IP}:${DSH_HTTPS_PORT}" \
      --trusted-host "${DSH_LAN_IP}:${DSH_WEB_PORT}" \
      --trusted-host "127.0.0.1:${DSH_WEB_PORT}" &
    DSH_PID=$!
  fi
  if ! kill -0 $RELAY_PID 2>/dev/null; then
    log "⚠ TLS relay 挂了, 重启 ..."
    node /usr/local/bin/dsh-tls-relay.js \
      0.0.0.0 "$DSH_HTTPS_PORT" "$SERVER_PEM" \
      127.0.0.1 "$DSH_WEB_PORT" "$DSH_TRUSTED_AUTHORITY" &
    RELAY_PID=$!
  fi
  sleep 5
done