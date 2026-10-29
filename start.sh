#!/bin/sh
# qq-bridge 启动器（macOS / Linux）—— 对应上游 Windows 的 start.bat
#
# 用法：
#   ./start.sh            前台守护：崩溃 5 秒后自动重启
#   ./start.sh --once     只跑一次，退出即结束（调试用）
#   DSH_AUTODETECT=0 ./start.sh   跳过 DSH 端口自动发现
set -u
cd "$(dirname "$0")" || exit 1

if [ ! -f config.json ]; then
  echo "缺少 config.json：先执行 cp config.example.json config.json 并填好参数" >&2
  exit 1
fi

# 配置文件里有 QQ 的 OneBot accessToken 与 DSH 凭据，收紧到当前用户可读写。
if [ "$(uname -s)" = "Darwin" ] || [ "$(uname -s)" = "Linux" ]; then
  chmod 600 config.json 2>/dev/null || true
  [ -d state ] && chmod 700 state 2>/dev/null || true
fi

# 收紧 state/ 的 ACL（Windows 走 icacls，macOS/Linux 走 chmod；失败不阻塞）
node scripts/harden-state-acl.mjs --quiet || true

# DSH 桌面版的 Host API 端口每次启动都会变，先探一次写回 config.json。
# 想固定连 dsh web 的 3080，就用 DSH_AUTODETECT=0 关掉。
if [ "${DSH_AUTODETECT:-1}" = "1" ]; then
  node scripts/detect-dsh-port.mjs --write --quiet || echo "（DSH 端口自动发现失败，沿用 config.json 里的 dsh.baseUrl）"
fi

if [ "${1:-}" = "--once" ]; then
  exec node src/bridge.js
fi

# ── 单一守护锁 ──────────────────────────────────────────────────────────────
#
# 为什么需要：launchd 的 KeepAlive 和本脚本的 while 循环是两个监管者。
# 实测 2026-10-29 14:33:52 / 14:34:30 日志里出现过多份「桥接已启动」，
# 13:09 也见过两个 node 进程并存 5 秒。重复实例的后果不是"多跑一个"这么简单：
#   · 各自轮换 agentToken → 在途回合的 MCP 发送全部 403
#   · 各自调度 proactive → 同一个人被连戳两次
#   · 各自消费同一条 QQ 事件 → 同一条消息被回两遍
# bridge.js 自己有 state/*.lock，但它按「控制台端口是否被占」判活；
# 端口还没绑上的那几百毫秒里两个实例都会认为自己是第一个。
# 所以在这里用 mkdir 原子锁再兜一层：拿不到锁就安静退出（exit 0），
# 让 launchd 认为这次启动"正常"，不会变成重启风暴。
LOCKDIR="state/.start.lock"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  holder=$(cat "$LOCKDIR/pid" 2>/dev/null || echo '?')
  if [ "$holder" != '?' ] && kill -0 "$holder" 2>/dev/null; then
    echo "[$(date '+%F %T')] 已有守护进程在跑（PID ${holder}），本实例退出。"
    exit 0
  fi
  echo "[$(date '+%F %T')] 清理过期锁（PID $holder 已不存在）"
  rm -rf "$LOCKDIR"
  mkdir "$LOCKDIR" 2>/dev/null || { echo "拿不到锁，退出。"; exit 0; }
fi
echo $$ > "$LOCKDIR/pid"
trap 'rm -rf "$LOCKDIR"' EXIT INT TERM

while :; do
  node src/bridge.js
  code=$?
  if [ "$code" -eq 2 ]; then
    echo "[$(date '+%F %T')] 已有一个实例在运行，退出。"
    exit 2
  fi
  echo "[$(date '+%F %T')] bridge 退出（code $code），5 秒后重启…"
  sleep 5
done
