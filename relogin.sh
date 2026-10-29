#!/usr/bin/env bash
# 重新登录 QQ（带冷却），专治「扫完就被踢」。
#
# 为什么需要冷却：实测 10-29 13:15 扫码成功，13:15:23 桥接立刻挂上 WS，
# 13:16:02 收到陌生人临时消息，13:18:31 就 [KickedOffLine]「登录已失效」——
# 只活了 3 分半。而 10-28 19:54 那次扫完不再折腾，活了 16 小时。
# 所以顺序很重要：先让 NapCat 自己安静待一会儿，再让桥接接上。
#
# 用法：
#   ./relogin.sh              默认冷却 10 分钟
#   ./relogin.sh 300          冷却 5 分钟
#   ./relogin.sh 0            不冷却（不推荐）
#
# 只扫一次。二维码每 80 秒自动换，失败就重跑本脚本，别连扫。
set -uo pipefail
cd "$(dirname "$0")" || exit 1

COOLDOWN="${1:-600}"
LABEL="com.local.qq-bridge"
UID_NUM="$(id -u)"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# ── 1. 先把桥接摘下来，免得它第一时间挂上去 ──────────────────────────────
say "1/5 停掉桥接（登录冷却期间不连 OneBot）"
launchctl bootout "gui/${UID_NUM}/${LABEL}" 2>/dev/null || true
for _ in $(seq 1 15); do pgrep -f "node src/bridge.js" >/dev/null || break; sleep 1; done
pgrep -f "node src/bridge.js" >/dev/null && { pkill -f "node src/bridge.js"; sleep 2; }
echo "  桥接已停"

# ── 2. 确保容器在跑 ────────────────────────────────────────────────────
say "2/5 确保 NapCat 容器在跑"
if ! docker ps --format '{{.Names}}' | grep -qx napcat; then
  docker start napcat >/dev/null 2>&1
  echo "  已启动容器，等它起来…"
  sleep 8
fi
docker ps --format '{{.Names}}\t{{.Status}}' | grep -x "$(printf 'napcat\t%s' "$(docker ps --format '{{.Status}}' --filter name=napcat)")" >/dev/null 2>&1
echo "  $(docker ps --format '{{.Status}}' --filter name=napcat)"

# ── 3. 取最新二维码并打开 ──────────────────────────────────────────────
say "3/5 抓取最新二维码（80 秒有效，扫一次就好）"
t0=$(date +%s)
got=""
for i in $(seq 1 60); do
  ts=$(docker exec napcat stat -c '%Y' /app/napcat/cache/qrcode.png 2>/dev/null || echo 0)
  if [ "$ts" != "0" ] && [ $(( $(date +%s) - ts )) -lt 75 ]; then
    docker cp napcat:/app/napcat/cache/qrcode.png ./qrcode.png >/dev/null 2>&1 && got=1 && break
  fi
  sleep 2
done
if [ -z "$got" ]; then
  echo "  ⚠️ 没拿到新鲜二维码。可能已经在登录中，或容器还在初始化。" >&2
  echo "     稍后手动跑：docker cp napcat:/app/napcat/cache/qrcode.png ./qrcode.png" >&2
else
  echo "  已保存 ./qrcode.png（生成于 $(docker exec napcat stat -c '%y' /app/napcat/cache/qrcode.png 2>/dev/null | cut -d. -f1)）"
  [ "$(uname -s)" = "Darwin" ] && open ./qrcode.png
fi

# ── 4. 等登录成功 ──────────────────────────────────────────────────────
say "4/5 等待扫码 + 登录成功（最多 5 分钟）"
online=""
for i in $(seq 1 100); do
  if docker logs --since 6m napcat 2>&1 | grep -aq "账号状态变更为在线"; then online=1; break; fi
  if docker logs --since 6m napcat 2>&1 | grep -aq "KickedOffLine"; then
    echo "  ⚠️ 刚登上去又被踢了 —— 这个号的风控已经很紧，见下面建议" >&2
  fi
  sleep 3
done
if [ -z "$online" ]; then
  echo "  未检测到「账号状态变更为在线」。重跑本脚本换一张码，不要连扫。" >&2
  say "桥接保持停止状态。要恢复旧行为：launchctl bootstrap gui/${UID_NUM} ~/Library/LaunchAgents/${LABEL}.plist"
  exit 1
fi
echo "  ✅ 账号在线"

# ── 5. 冷却，然后挂回桥接 ──────────────────────────────────────────────
if [ "$COOLDOWN" -gt 0 ]; then
  say "5/5 冷却 ${COOLDOWN}s：这期间谁都不碰这个号（登录瞬间的密集行为是最可疑的特征）"
  left="$COOLDOWN"
  while [ "$left" -gt 0 ]; do
    printf '\r  还剩 %3ds ' "$left"
    sleep 5; left=$((left - 5))
  done
  printf '\r  冷却完成   \n'
else
  say "5/5 冷却已跳过（COOLDOWN=0）"
fi

launchctl bootstrap "gui/${UID_NUM}" "$HOME/Library/LaunchAgents/${LABEL}.plist" 2>/dev/null || \
  launchctl kickstart "gui/${UID_NUM}/${LABEL}" 2>/dev/null || true
sleep 4
if pgrep -f "node src/bridge.js" >/dev/null; then
  echo "  ✅ 桥接已恢复（PID $(pgrep -f 'node src/bridge.js' | head -1)）"
  tail -6 /tmp/qq-bridge.out.log | sed 's/^/     /'
else
  echo "  ⚠️ 桥接没起来，手动跑：launchctl kickstart -k gui/${UID_NUM}/${LABEL}" >&2
fi
