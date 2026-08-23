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
# 必须显式提供 DSH_LAN_IP(relay 权威)。不提供则 fail-closed, 避免特权面暴露全网(见 review S1)
DSH_LAN_IP="${DSH_LAN_IP:-}"
# 受信权威默认绑定 web 端口(而非硬编码 3080)——改 DSH_WEB_PORT 时默认权威自动跟随(见 review P1)
DSH_TRUSTED_AUTHORITY="${DSH_TRUSTED_AUTHORITY:-${DSH_LAN_IP}:${DSH_WEB_PORT}}"

log()  { echo "[entrypoint] $*"; }   # 定义在最先, 供下方 S1 校验使用

# ---------------------------------------------------------------------------
# FAIL-CLOSED 启动校验 (review S1):
#   relay 绑 0.0.0.0(全网) + host 网络时, DSH_TRUSTED_AUTHORITY 若解析为 loopback,
#   dsh 的 loopback-only 特权方法(fence)会对全网放行 → 特权面暴露。
#   因此: 未配置 DSH_LAN_IP, 或 TRUSTED_AUTHORITY 为 loopback/localhost 时直接退出。
#   (注意: 证书 SAN 需要 DSH_LAN_IP 为真实 IP, loopback 也会生成非法 IP SAN)
# ---------------------------------------------------------------------------
is_loopback() { # 检测 host 部分是否 loopback (含 IPv6 [::1] 方括号形式, review L1)
  case "${1%%:*}" in
    localhost|127.*|::1|"[::1"|"["*) return 0 ;;
    *) return 1 ;;
  esac
}

if [ -z "$DSH_LAN_IP" ]; then
  echo "[entrypoint] ❌ 未设置 DSH_LAN_IP(部署机局域网 IP)。为保证不暴露特权面,拒绝启动。" >&2
  echo "  请配置: cp .env.example .env 并在 .env 填 DSH_LAN_IP=你的实际IP" >&2
  exit 1
fi
# relay 若绑 loopback(只本机), 则 loopback 权威安全; 否则(绑全网)必须非 loopback 权威
RELAY_BIND_LOOPBACK="${DSH_RELAY_BIND_LOOPBACK:-0}"
if [ "$RELAY_BIND_LOOPBACK" = "1" ]; then
  log "relay 将绑 loopback, loopback 权威允许"
else
  if is_loopback "$DSH_TRUSTED_AUTHORITY"; then
    echo "[entrypoint] ❌ DSH_TRUSTED_AUTHORITY($DSH_TRUSTED_AUTHORITY) 是 loopback, 但 relay 绑全网。此配置会让特权方法对全网放行(fail-open),拒绝启动。" >&2
    echo "  请在 .env 设置非 loopback 的 DSH_LAN_IP, 或改用 DSH_RELAY_BIND_LOOPBACK=1" >&2
    exit 1
  fi
fi

# 默认 agent provider envs (llama.cpp/vLLM 端点不校验 key 值, 但 dsh 依此做凭据存在性检查)
export OLLAMA_API_KEY="${OLLAMA_API_KEY:-ollama-local}"
export B70_API_KEY="${B70_API_KEY:-local-b70}"

mkdir -p "$DSH_HOME"

TLS_DIR="$DSH_HOME/tls"
CERT_PEM="$TLS_DIR/cert.pem"
KEY_PEM="$TLS_DIR/key.pem"
SERVER_PEM="$TLS_DIR/server.pem"   # relay 需要 cert+key 合并

# ---------------------------------------------------------------------------
# 1) TLS 证书准备
#    规则:
#      - 三者齐全 (cert.pem + key.pem + server.pem)  -> 复用 (既有已导入的旧证书)
#      - 只有 cert.pem + key.pem, 无 server.pem       -> 由前两者合并生成 server.pem
#      - 全无                                     -> 自动生成新自签证书 (含 LAN IP + localhost SAN)
# ---------------------------------------------------------------------------
generate_cert_linux() {
  # 自签证书 SAN (dsh GUI 是 SecureContext: 需 HTTPS + 受信 SAN)
  #  loopback 权威时用 DNS:localhost(避免非法 IP:localhost SAN, review N2); 否则用真实 IP
  if is_loopback "$DSH_LAN_IP"; then
    local san="DNS:localhost"
  else
    local san="IP:${DSH_LAN_IP},DNS:localhost"
  fi
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$KEY_PEM" -out "$CERT_PEM" -days 825 \
    -subj "/CN=dsh-gui" \
    -addext "subjectAltName=${san}"
  # 合并为 relay 用的 server.pem (cert 在前 key 在后)
  cat "$CERT_PEM" "$KEY_PEM" > "$SERVER_PEM"
  log "🔐 已自动生成新自签证书 → $TLS_DIR (SAN: ${san})"
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
# chown 需 root 权限(entrypoint 以 root 运行才有)。降权后的工作进程(node)才能读证书。
: "${DSH_RUN_UID:=1000}" "${DSH_RUN_GID:=1000}"   # set -u 安全默认
chmod 600 "$KEY_PEM" "$SERVER_PEM" 2>/dev/null || true
chown "$DSH_RUN_UID:$DSH_RUN_GID" "$CERT_PEM" "$KEY_PEM" "$SERVER_PEM" 2>/dev/null || true
# 降权(非root)工作进程需能写 dsh 运行时数据目录。既有 root 属主目录(旧部署产物)需归给运行用户。
#   ⚠️ 不无条件 chown(C1 修复): 仅当属主为 root 且运行用户不可写时才接管——避免跨主机
#   把宿主用户自己的数据目录(.credentials.yaml 等)改成 1000:1000。已属运行用户的不动, 也省下
#   对大型 sessions/ 的无谓递归 chown。
ensure_writable() { # $1=路径; 属主为DSH_RUN_UID 或可写 → 不动; 否则 chown -R
  [ -z "$1" ] && return 0
  local owner
  owner=$(stat -c %u "$1" 2>/dev/null || echo "")
  if [ -n "$owner" ] && [ "$owner" != "$DSH_RUN_UID" ]; then
    chown -R "$DSH_RUN_UID:$DSH_RUN_GID" "$1" 2>/dev/null || true
  fi
}
for sub in sessions storages integrations profiles; do
  [ -e "$DSH_HOME/$sub" ] && ensure_writable "$DSH_HOME/$sub"
done
ensure_writable "$DSH_HOME/settings.yaml"
ensure_writable "$DSH_HOME/.credentials.yaml"
# $DSH_HOME 根本身: 运行用户可写则不动(root属主时接管)
owner=$(stat -c %u "$DSH_HOME" 2>/dev/null || echo "")
if [ -n "$owner" ] && [ "$owner" != "$DSH_RUN_UID" ]; then
  chown "$DSH_RUN_UID:$DSH_RUN_GID" "$DSH_HOME" 2>/dev/null || true
fi
log "运行数据所有权检查完成 (仅接管非 $DSH_RUN_UID 属主路径)"

# ---------------------------------------------------------------------------
# 2) 启动 TLS relay + dsh web 双进程, 互相看护
# ---------------------------------------------------------------------------
# relay 默认绑全网(0.0.0.0)供 LAN/WARP 访问; DSH_RELAY_BIND_LOOPBACK=1 时只绑本机
if [ "${DSH_RELAY_BIND_LOOPBACK:-0}" = "1" ]; then
  RELAY_BIND="127.0.0.1"
  log "relay 仅绑本机 loopback (DSH_RELAY_BIND_LOOPBACK=1)"
else
  RELAY_BIND="0.0.0.0"
fi
log "启动 TLS relay  https://${RELAY_BIND}:${DSH_HTTPS_PORT} -> http://127.0.0.1:${DSH_WEB_PORT} (trusted-as ${DSH_TRUSTED_AUTHORITY})"
runuser -u node -- node /usr/local/bin/dsh-tls-relay.js \
  "$RELAY_BIND" "$DSH_HTTPS_PORT" "$SERVER_PEM" \
  127.0.0.1 "$DSH_WEB_PORT" "$DSH_TRUSTED_AUTHORITY" &
RELAY_PID=$!

log "启动 dsh web  http://127.0.0.1:${DSH_WEB_PORT}  (provider 默认经 DSH_HOME settings)"
runuser -u node -- env DSH_HOME="$DSH_HOME" dsh web \
  --no-open \
  --host 127.0.0.1 \
  --port "$DSH_WEB_PORT" \
  --trusted-host "${DSH_LAN_IP}:${DSH_HTTPS_PORT}" \
  --trusted-host "${DSH_LAN_IP}:${DSH_WEB_PORT}" \
  --trusted-host "127.0.0.1:${DSH_WEB_PORT}" &
DSH_PID=$!

# 信号处理: 任一挂掉重启 (看护循环)
trap 'log "收到信号, 退出"; kill $RELAY_PID $DSH_PID 2>/dev/null; exit 0' TERM INT

# 看护循环 (review W1 修复): 带连续失败计数。进程秒崩时(如配置错误)停止自动重启,
#   交由 compose restart policy 重建, 避免无限刷日志。
#   注意: 重启路径必须用内联 &+$! 捕获 PID——不能用 `$(start_dsh)` 命令替换,
#   (后台子进程继承命令替换管道的写端, 常驻进程永不关闭 stdout → 永久阻塞)。
declare -a FAIL_COUNT=()
DECAY_LIMIT=20        # 连续失败达此数 → 判定"持久性崩溃", 停止自动重启

while true; do
  if ! kill -0 $DSH_PID 2>/dev/null; then
    log "⚠ dsh web 挂了, 重启 ..."
    runuser -u node -- env DSH_HOME="$DSH_HOME" dsh web \
      --no-open --host 127.0.0.1 --port "$DSH_WEB_PORT" \
      --trusted-host "${DSH_LAN_IP}:${DSH_HTTPS_PORT}" \
      --trusted-host "${DSH_LAN_IP}:${DSH_WEB_PORT}" \
      --trusted-host "127.0.0.1:${DSH_WEB_PORT}" &
    DSH_PID=$!
    FAIL_COUNT[0]=$(( ${FAIL_COUNT[0]:-0} + 1 ))
  else
    FAIL_COUNT[0]=0   # 健康时清零
  fi
  if ! kill -0 $RELAY_PID 2>/dev/null; then
    log "⚠ TLS relay 挂了, 重启 ..."
    runuser -u node -- node /usr/local/bin/dsh-tls-relay.js \
      "$RELAY_BIND" "$DSH_HTTPS_PORT" "$SERVER_PEM" \
      127.0.0.1 "$DSH_WEB_PORT" "$DSH_TRUSTED_AUTHORITY" &
    RELAY_PID=$!
    FAIL_COUNT[1]=$(( ${FAIL_COUNT[1]:-0} + 1 ))
  else
    FAIL_COUNT[1]=0
  fi
  # 任一侧持续秒崩 → 判定持久性故障, 停止内部重启(交 restart policy / 人工)
  if [ "${FAIL_COUNT[0]:-0}" -ge "$DECAY_LIMIT" ] || [ "${FAIL_COUNT[1]:-0}" -ge "$DECAY_LIMIT" ]; then
    log "❌ 检测到持久性崩溃(连续 ${DECAY_LIMIT}+ 次)。停止自动重启工作集。"
    log "   保留容器 alive; 请检查日志找根因, 或由 compose restart policy 重建。" >&2
    # 等闲置, 不无限刷
    sleep 60
    FAIL_COUNT=(0 0)   # 重置, 给外部重启机会
    continue
  fi
  sleep 5
done