#!/bin/bash
# 本地冒烟自检(= CI smoke 步骤的复刻)。验证镜像能起、证书自动生成、web/relay 可达、工作进程非root。
# dsh >= 0.1.2: web 引入 access token —— 容器日志打印带 token 的访问链接,
#   后续访问要么 URL 带 ?token=..., 要么保存 Set-Cookie 的 auth cookie。本脚本两者都验。
# 用法: bash docker/test/smoke.sh <镜像名>
set -euo pipefail
IMG="${1:-smoke:latest}"
NAME="dsh-smoke-local"

echo "### 起临时容器(loopback模式, 测试段IP) ###"
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" \
  -e DSH_LAN_IP=203.0.113.1 \
  -e DSH_TRUSTED_AUTHORITY=203.0.113.1:3080 \
  -e DSH_RELAY_BIND_LOOPBACK=1 \
  "$IMG" >/dev/null

# 等证书生成(entrypoint)
for i in $(seq 1 30); do
  if docker exec "$NAME" sh -c 'test -f /dsh-home/tls/server.pem' 2>/dev/null; then break; fi
  sleep 2
done

echo "### 1. 证书自动生成 ###"
docker exec "$NAME" sh -c 'ls /dsh-home/tls/ | tr "\n" " "'
echo
docker exec "$NAME" sh -c 'grep -q "BEGIN CERTIFICATE" /dsh-home/tls/server.pem && echo "server.pem 合法"'

# --- dsh >= 0.1.2: 从容器日志提取 access token (启动时打印的带 token 访问链接) ---
# 等待 dsh web 就绪(日志出现 "dsh web:" 行, 内含 ?token=...), 最长 60s
TOKEN=""
for i in $(seq 1 30); do
  # ⚠️ 管道末尾必须 || true: set -euo pipefail 下, 首轮容器日志尚无 dsh web 行时 grep 无匹配
  #    返回非零 → 整个命令替换失败 → 脚本立即静默 exit 1(跳过后续轮询)。加 || true 让空结果
  #    只产生空 TOKEN, 进入下一轮等待(见 CI EINVALID/bug 修复)。
  TOKEN=$(docker logs "$NAME" 2>&1 | grep -oE 'http://[^[:space:]]*\\?token=[A-Za-z0-9_-]+' | tail -1 | sed -E 's/.*token=//' || true)
  [ -n "$TOKEN" ] && break
  sleep 2
done
if [ -z "$TOKEN" ]; then
  echo "❌ FAIL: 容器日志未找到带 token 的访问链接(dsh web 未就绪?)" >&2
  docker logs "$NAME" 2>&1 | tail -30 >&2 || true
  docker rm -f "$NAME" >/dev/null 2>&1
  exit 1
fi
echo "### 2. access token 已从容器日志提取 ###"
echo "  token=${TOKEN:0:8}... (${#TOKEN} chars)"

echo "### 3. web(3080) 认证行为 ###"
# 无 token → 401 (dsh >= 0.1.2 的 access-token 保护生效)
CODE_NOTOKEN=$(docker exec "$NAME" sh -c 'curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3080/')
if [ "$CODE_NOTOKEN" != "401" ]; then
  echo "❌ FAIL: 无 token 访问应返回 401, 实际 $CODE_NOTOKEN" >&2
  docker rm -f "$NAME" >/dev/null 2>&1
  exit 1
fi
echo "  无 token → 401 ✓"
# URL 带 token → 303 (Set-Cookie 签发 auth cookie)
CODE_TOKEN=$(docker exec -e DSH_TOK="$TOKEN" "$NAME" sh -c 'curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:3080/?token=$DSH_TOK"')
if [ "$CODE_TOKEN" != "303" ]; then
  echo "❌ FAIL: URL token 访问应返回 303, 实际 $CODE_TOKEN" >&2
  docker rm -f "$NAME" >/dev/null 2>&1
  exit 1
fi
echo "  URL ?token=... → 303 ✓"
# Cookie 方式: 保存 Set-Cookie 后, 不带 token 访问应 200
docker exec -e DSH_TOK="$TOKEN" "$NAME" sh -c 'curl -s -c /tmp/dsh-smoke-cj.txt -o /dev/null "http://127.0.0.1:3080/?token=$DSH_TOK"'
if ! docker exec "$NAME" sh -c 'grep -q "dsh-auth-" /tmp/dsh-smoke-cj.txt'; then
  echo "❌ FAIL: token 响应未签发 dsh-auth-* cookie" >&2
  docker rm -f "$NAME" >/dev/null 2>&1
  exit 1
fi
CODE_COOKIE=$(docker exec "$NAME" sh -c 'curl -s -b /tmp/dsh-smoke-cj.txt -o /dev/null -w "%{http_code}" http://127.0.0.1:3080/')
if [ "$CODE_COOKIE" != "200" ]; then
  echo "❌ FAIL: cookie 访问应返回 200, 实际 $CODE_COOKIE" >&2
  docker rm -f "$NAME" >/dev/null 2>&1
  exit 1
fi
echo "  Cookie (dsh-auth-*) → 200 ✓"

echo "### 4. relay(8443) 可达(loopback bind, 带 token) ###"
RELAY_CODE=$(docker exec -e DSH_TOK="$TOKEN" "$NAME" sh -c 'curl -kfsS -o /dev/null -w "%{http_code}" "https://127.0.0.1:8443/?token=$DSH_TOK"')
if ! echo "$RELAY_CODE" | grep -qE '^(30[0-9]|200)$'; then
  echo "❌ FAIL: relay(8443) 带 token 访问应返回 2xx/3xx, 实际 $RELAY_CODE" >&2
  docker rm -f "$NAME" >/dev/null 2>&1
  exit 1
fi
echo "OK (relay → $RELAY_CODE)"

echo "### 5. 工作进程属主非root ###"
# 匹配真正的 node 主进程(排除 runuser/包装), 其 PPID 是 runuser
NONROOT=$(docker exec "$NAME" sh -c 'ps -eo user,args | grep -E "^node .*dsh|^node .*relay|^[0-9]+ +node .*dsh" | grep -v grep | head -2' 2>/dev/null)
echo "$NONROOT"
# 硬化(S2): 非 root 是 CI 对 H1 的硬保证——找不到 node 主进程即失败, 不软通过
if echo "$NONROOT" | grep -q "^node " &&
   echo "$NONROOT" | grep -qE "dsh web|dsh-tls-relay"; then
  echo "非root进程 ✓ (dsh/relay 主进程属主=node)"
else
  echo "❌ FAIL: 未找到属主为 node 的工作进程(H1 要求)" >&2
  docker rm -f "$NAME" >/dev/null 2>&1
  exit 1
fi

echo "### 6. 看护自愈: 杀 dsh web worker, 验证自动拉起 (review W1/T1) ###"
# 必须精确杀 node worker(-u node 排除 root 的 runuser wrapper): 否则杀 wrapper 而 worker
# 存活 → watchdog 重启因 3080 被孤儿 worker 占用 EADDRINUSE 秒崩, 且 heal 判定是假阳性,
# 测不到真正的 W1 重启路径(见 review T1)。
DSH_WEB_PID=$(docker exec "$NAME" sh -c 'pgrep -u node -f "dsh web" | head -1' 2>/dev/null)
if [ -z "$DSH_WEB_PID" ]; then
  echo "⚠ 找不到 dsh web worker 进程, 跳过自愈验证" >&2
else
  echo "  杀掉 dsh web worker (PID $DSH_WEB_PID)..."
  docker exec "$NAME" sh -c "kill -9 $DSH_WEB_PID" 2>/dev/null
  sleep 1
  # 看护循环 5s 一轮; 新 worker 冷启动(node 加载整个 dsh)在 dsh>=0.1.2 明显变慢,
  #   12s 只够起进程不够 web 就绪(实测 T+6s 起 PID、T+9-12s 才 401)。给 30s 观察窗口。
  echo "  ⏳ 等待自愈 (最长 30s, 每 2s 探测)..."
  HEALED=0
  for i in $(seq 1 15); do
    sleep 2
    NEWPID=$(docker exec "$NAME" sh -c 'pgrep -u node -f "dsh web" | head -1' 2>/dev/null)
    # dsh 每次启动会签发新 access token: worker 重启后旧 TOKEN 失效(412/401)。
    # 因此重新从日志提取最新 token(tail -1 = 最近一次 dsh web 启动打印的链接)再用它探测。
    NEWTOK=$(docker logs "$NAME" 2>&1 | grep -oE 'http://[^[:space:]]*\\?token=[A-Za-z0-9_-]+' | tail -1 | sed -E 's/.*token=//' || true)
    if [ -n "$NEWPID" ] && [ "$NEWPID" != "$DSH_WEB_PID" ] && [ -n "$NEWTOK" ]; then
      # 新 token 应能拿到(worker 重启后重新签发)。curl 若返回非 401(200/303), 说明 worker
      # 真正起来且 token 有效 → 判定自愈成功。401 说明仍在初始化或 token 尚未签发。
      CODE=$(docker exec -e DSH_TOK="$NEWTOK" "$NAME" sh -c 'curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:3080/?token=$DSH_TOK"' 2>/dev/null || echo "000")
      if [ "$CODE" != "401" ] && [ "$CODE" != "000" ]; then
        echo "  ✓ 已自愈: 新 PID=$NEWPID (原=$DSH_WEB_PID), 3080 恢复 (HTTP $CODE)"
        HEALED=1
        break
      fi
    fi
  done
  if [ "$HEALED" != "1" ]; then
    echo "❌ FAIL: dsh web worker 被杀后 30s 内未恢复(看护死锁 W1)" >&2
    docker rm -f "$NAME" >/dev/null 2>&1
    exit 1
  fi
fi

echo "### SMOKE PASS ###"
docker rm -f "$NAME" >/dev/null 2>&1
