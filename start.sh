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
