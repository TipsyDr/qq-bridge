#!/usr/bin/env bash
# 重新登录 QQ：抓新码 → 等上线 → 恢复桥接。冷却默认关闭。
#
# ── 关于「冷却」：我一开始把它当默认行为，是错的，留这段记录免得再走一遍 ──
#
# 当时的假设：10-29 13:15 扫码，13:15:23 桥接挂上 WS，13:18:31 被
# [KickedOffLine] 踢掉，只活 3 分 22 秒；而 10-28 19:54 那次活了 16 小时
# —— 于是猜「扫完别让桥接立刻接上」。
#
# 这个假设被自己的日志推翻了：10-28 19:54:14 扫码，桥接 **19:54:33** 就挂上
# WS（19 秒），19:58 连好友备注和表情包都同步完了，然后**照样活了 16 小时**。
# 所以「桥接接得快」不是被踢的原因，两者没有相关性。
#
# 真正对得上的差异只有一个：13:16:02 进了一条陌生人临时消息（2747277822），
# 2 分半后被踢。这个号 10-28 已有 serverErrorCode: 168「账号近期存在安全风险」，
# 陌生人临时会话是被标记账号的高风险特征。
#
# 冷却仍然保留，但改成显式开启，默认 0：想在排查时控制变量可以用，
# 别再把它当「必要步骤」。
#
# 用法：
#   ./relogin.sh              默认不冷却，登录成功立刻恢复桥接
#   ./relogin.sh 600          手动要 10 分钟冷却（排查用）
#
# 这个脚本真正省事的地方：帮你取到**新鲜**二维码（80 秒一换，抓旧的白扫）、
# 盯着登录结果、登录后自动把桥接拉回来，不用来回敲命令。
#
# 只扫一次。失败就重跑本脚本，别连扫（10-28 13:49+13:55 连扫两次、18:45/47/53
# 连扫三次，之后都在半小时内被踢 —— 这个相关性比「桥接时机」强得多）。
set -uo pipefail
cd "$(dirname "$0")" || exit 1

COOLDOWN="${1:-0}"
LABEL="com.local.qq-bridge"
UID_NUM="$(id -u)"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# ── 1. 先摘桥接：只是为了别在没登录时刷一堆重连错误日志 ────────────────
BRIDGE_BOOTED_OUT=""
restore_bridge() {
  # 被打断（Ctrl+C / kill）时也把桥接放回去：否则 launchd 里没有这个 job，
  # 桥接会一直停着，而且日志里什么都不会说 —— 实测踩过一次。
  if [ "${BRIDGE_BOOTED_OUT}" = "1" ] && ! pgrep -f "node src/bridge.js" >/dev/null; then
    launchctl bootstrap "gui/${UID_NUM}" "$HOME/Library/LaunchAgents/${LABEL}.plist" 2>/dev/null \
      || launchctl kickstart "gui/${UID_NUM}/${LABEL}" 2>/dev/null || true
    echo "  （退出前已把桥接重新挂上）"
  fi
}
trap restore_bridge EXIT INT TERM

say "1/5 停掉桥接（避免它在未登录时刷重连错误）"
BRIDGE_BOOTED_OUT="1"
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
ONEBOT_TOKEN=$(python3 -c "
import json,glob,sys
fs=glob.glob('$HOME/qq-bridge-napcat/config/onebot11_*.json')
for f in fs:
    try:
        d=json.load(open(f,encoding='utf-8'))
        s=(d.get('network') or {}).get('httpServers') or []
        if s and s[0].get('token'): print(s[0]['token']); break
    except Exception: pass
" 2>/dev/null)
online=""
for i in $(seq 1 100); do
  # 以 OneBot 自报状态为准：快速登录路径不会打「账号状态变更为在线」那行日志，
  # 早先只看日志会一直等下去（实测 17:1x 那次就是这样卡住，最后服务被 bootout 了却没恢复）。
  st=$(curl -s -m 4 -X POST http://127.0.0.1:3000/get_status \
        -H "Authorization: Bearer ${ONEBOT_TOKEN}" -H 'Content-Type: application/json' -d '{}' 2>/dev/null)
  case "$st" in *'"online":true'*) online=1; break;; esac
  if docker logs --since 3m napcat 2>&1 | grep -aq "KickedOffLine"; then
    echo "  ⚠️ 刚登上去又被踢了 —— 这个号的风控已经很紧" >&2
  fi
  sleep 3
done
if [ -z "$online" ]; then
  echo "  未检测到「账号状态变更为在线」。重跑本脚本换一张码，不要连扫。" >&2
  say "桥接保持停止状态。要恢复旧行为：launchctl bootstrap gui/${UID_NUM} ~/Library/LaunchAgents/${LABEL}.plist"
  exit 1
fi
echo "  ✅ 账号在线"

# ── 5. （可选）冷却，然后挂回桥接 ──────────────────────────────────────
if [ "$COOLDOWN" -gt 0 ]; then
  say "5/5 冷却 ${COOLDOWN}s（排查用；默认不启用，见文件头说明）"
  left="$COOLDOWN"
  while [ "$left" -gt 0 ]; do
    printf '\r  还剩 %3ds ' "$left"
    sleep 5; left=$((left - 5))
  done
  printf '\r  冷却完成   \n'
else
  say "5/5 无冷却，直接挂回桥接"
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
