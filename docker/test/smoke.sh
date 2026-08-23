#!/bin/bash
# 本地冒烟自检(= CI smoke 步骤的复刻)。验证镜像能起、证书自动生成、web/relay 可达、工作进程非root。
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
  docker exec "$NAME" sh -c 'test -f /dsh-home/tls/server.pem' 2>/dev/null && break
  sleep 2
done

echo "### 1. 证书自动生成 ###"
docker exec "$NAME" sh -c 'ls /dsh-home/tls/ | tr "\n" " "'
echo
docker exec "$NAME" sh -c 'grep -q "BEGIN CERTIFICATE" /dsh-home/tls/server.pem && echo "server.pem 合法"'

echo "### 2. web(3080) 可达 ###"
docker exec "$NAME" sh -c 'curl -fsS http://127.0.0.1:3080/ >/dev/null 2>&1 && echo OK || (echo FAIL-WEB; exit 1)'

echo "### 3. relay(8443) 可达(loopback bind) ###"
docker exec "$NAME" sh -c 'curl -kfsS https://127.0.0.1:8443/ >/dev/null 2>&1 && echo OK || (echo FAIL-RELAY; exit 1)'

echo "### 4. 工作进程属主非root ###"
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

echo "### 5. 看护自愈: 杀 dsh web 进程, 验证 5-10s 内自动拉起 (review W1) ###"
# 找到 dsh web 主进程 PID 并杀掉, 验证 entrypoint 看护循环能重启它(不因命令替换死锁)
DSH_WEB_PID=$(docker exec "$NAME" sh -c 'pgrep -f "dsh web" | head -1' 2>/dev/null)
if [ -z "$DSH_WEB_PID" ]; then
  echo "⚠ 找不到 dsh web 进程, 跳过自愈验证" >&2
else
  echo "  杀掉 dsh web (PID $DSH_WEB_PID)..."
  docker exec "$NAME" sh -c "kill -9 $DSH_WEB_PID" 2>/dev/null
  # 看护循环 5s 一轮, 给 10s 观察窗口
  HEALED=0
  for i in $(seq 1 10); do
    sleep 1
    NEWPID=$(docker exec "$NAME" sh -c 'pgrep -f "dsh web" | head -1' 2>/dev/null)
    if [ -n "$NEWPID" ] && [ "$NEWPID" != "$DSH_WEB_PID" ]; then
      echo "  ✓ 已自愈: 新 PID=$NEWPID (原=$DSH_WEB_PID)"
      HEALED=1
      break
    fi
  done
  if [ "$HEALED" != "1" ]; then
    echo "❌ FAIL: dsh web 被杀后 10s 内未恢复(看护死锁 W1)" >&2
    docker rm -f "$NAME" >/dev/null 2>&1
    exit 1
  fi
fi

echo "### SMOKE PASS ###"
docker rm -f "$NAME" >/dev/null 2>&1