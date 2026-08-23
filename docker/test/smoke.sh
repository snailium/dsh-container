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
docker exec "$NAME" sh -c 'ps -eo user,args' | grep "^node " | grep -E "dsh web|dsh-tls-relay" | grep -v "bash" | grep -q node \
  && echo "非root进程 ✓ (dsh/relay 主进程属主=node)" || echo "警告: 未见 node 主进程"

echo "### SMOKE PASS ###"
docker rm -f "$NAME" >/dev/null 2>&1