#!/bin/sh
# DSH 重启后跑一次：重新发现 Host API 端口并把桥重启过去。
# DSH 桌面版的端口每次启动都变，桥只在启动时读一次 config.json 里的 dsh.baseUrl，
# 所以 DSH 一重启桥就连不上，必须重同步。
cd "$(dirname "$0")" || exit 1
echo "→ 重新探测 DSH 端口…"
node scripts/detect-dsh-port.mjs --write || exit 1
echo "→ 重启桥（launchd）…"
launchctl kickstart -k "gui/$(id -u)/com.local.qq-bridge" 2>/dev/null \
  && echo "  已重启 com.local.qq-bridge" \
  || echo "  launchd 未加载，改用 ./start.sh 手动起"
sleep 10
TOK=$(cat state/console-token 2>/dev/null)
[ -n "$TOK" ] && curl -sS --max-time 6 "http://127.0.0.1:3100/api/status?token=$TOK" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); s=d['snowluma']; print(f\"  mode={d['mode']} dshReady={d['dshReady']} QQ在线={s['accountOnline']} good={s['good']}\")" 2>/dev/null \
  || echo "  （桥还没起来，看 /tmp/qq-bridge.out.log）"
