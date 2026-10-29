#!/usr/bin/env bash
# 重建 NapCat 容器：唯一目的 = 把 /dev/shm 从默认 64MB 提到 1GB。
#
# 为什么：NTQQ 是 Electron 应用（容器里有 qq / GPU / Utility 多进程），
# Chromium 系对 /dev/shm 很敏感，64MB 会直接崩。实测证据（2026-10-29）：
#   docker inspect → ShmSize=67108864（64MB，Docker 默认）
#   docker logs napcat | grep -c NativeCrashHandler = 30 条
#   当天 QQ Worker 被重启 15 次
# 崩溃 → 重启 → 再崩 的循环，会让风控看到「同一个号反复建立登录会话」，
# 这也是「扫完很快又被踢」的催化剂之一。
#
# 数据全部在宿主目录里（bind mount），容器本身是空壳：
#   ~/qq-bridge-napcat/config  -> /app/napcat/config
#   ~/qq-bridge-napcat/qqdata  -> /app/.config/QQ
# 所以重建容器不丢登录态，通常不需要重新扫码（entrypoint 带 -q 快速登录）。
set -uo pipefail
cd "$(dirname "$0")" || exit 1
IMAGE="mlikiowa/napcat-docker:latest"
NEW_SHM="1g"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

say "0/5 记录当前配置（可回滚）"
docker inspect napcat > /tmp/napcat-inspect-before.json 2>/dev/null && echo "  已存 /tmp/napcat-inspect-before.json"
docker inspect napcat --format 'ShmSize={{.HostConfig.ShmSize}}' | sed 's/^/  /'

say "1/5 停桥接（避免容器重建期间它疯狂重连）"
launchctl bootout "gui/$(id -u)/com.local.qq-bridge" 2>/dev/null || true
pkill -f "node src/bridge.js" 2>/dev/null || true
sleep 2
pgrep -f "node src/bridge.js" >/dev/null && echo "  ⚠️ 桥接仍在跑" || echo "  桥接已停"

say "2/5 停旧容器并改名备份（不删，随时可回滚）"
docker stop napcat >/dev/null 2>&1
docker rm -f napcat-old >/dev/null 2>&1
docker rename napcat napcat-old 2>&1 | sed 's/^/  /'
echo "  旧容器已保留为 napcat-old"

say "3/5 用 --shm-size=${NEW_SHM} 重建"
docker run -d --name napcat \
  --restart unless-stopped \
  --shm-size="${NEW_SHM}" \
  -e NAPCAT_UID="$(id -u)" \
  -e NAPCAT_GID="$(id -g)" \
  -e TZ=Asia/Shanghai \
  -p 127.0.0.1:3000:3000 \
  -p 127.0.0.1:3001:3001 \
  -p 127.0.0.1:6099:6099 \
  -v "$HOME/qq-bridge-napcat/config":/app/napcat/config \
  -v "$HOME/qq-bridge-napcat/qqdata":/app/.config/QQ \
  "${IMAGE}" -q 1162470069 >/dev/null && echo "  容器已启动"
sleep 10
docker ps --format '{{.Names}}\t{{.Status}}' --filter name=napcat | sed 's/^/  /'
echo -n "  新 ShmSize: "; docker inspect napcat --format '{{.HostConfig.ShmSize}}'

say "4/5 等 QQ 登录（快速登录，通常不用扫码）"
online=""
for i in $(seq 1 40); do
  if docker logs --since 3m napcat 2>&1 | grep -aq "账号状态变更为在线"; then online=1; break; fi
  sleep 4
done
if [ -n "$online" ]; then
  echo "  ✅ 快速登录成功，账号在线"
else
  echo "  ⚠️ 还没在线。可能需要扫码（上游 session 可能已被风控作废）"
  docker cp napcat:/app/napcat/cache/qrcode.png ./qrcode.png 2>/dev/null && {
    echo "  已取到 ./qrcode.png（生成于 $(docker exec napcat stat -c '%y' /app/napcat/cache/qrcode.png 2>/dev/null | cut -d. -f1)）"
    [ "$(uname -s)" = "Darwin" ] && open ./qrcode.png
  }
fi

say "5/5 恢复桥接"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.local.qq-bridge.plist" 2>/dev/null || \
  launchctl kickstart "gui/$(id -u)/com.local.qq-bridge" 2>/dev/null || true
sleep 5
pgrep -f "node src/bridge.js" >/dev/null && echo "  ✅ 桥接已恢复（PID $(pgrep -f 'node src/bridge.js' | head -1)）" || echo "  ⚠️ 桥接未起"

cat <<'EOF'

回滚（万一新容器有问题）：
  docker rm -f napcat && docker rename napcat-old napcat && docker start napcat
清理备份（确认稳定一天后再做）：
  docker rm -f napcat-old
EOF
