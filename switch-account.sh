#!/usr/bin/env bash
# 换协议端 QQ 号：把 NapCat 从旧号切到新号，并且**预先塞好 OneBot 网络配置**，
# 让桥接不用改一行就能接上。
#
# 为什么需要预先塞配置：NapCat 的 OneBot 配置是**按账号**存的文件
# （config/onebot11_<QQ>.json）。新号第一次登录时若没有这个文件，NapCat 会生成
# 一份默认值 —— 里面 `httpServers` / `websocketServers` 都是空数组，
# 于是 3000/3001 根本不会监听，桥接连不上，日志里只有 non-101。
# 所以要在登录前就把旧号的 network 段复制过去。
#
# 用法：
#   ./switch-account.sh 123456789
#   ./switch-account.sh 123456789 --keep-bridge   # 不停桥接（切换期间会刷重连错误）
#
# 切完之后要做的三件人肉事：
#   1) 新号必须已经加了「爸爸」「妈妈」为好友，否则无法私聊他们
#   2) 新号如果不在白名单里也没关系 —— 白名单管的是**对方**（OWNER_QQ 等），
#      和机器人自己的号无关，config.json 不用改
#   3) 手机 QQ 上把这个新号保持登录（多端同时在线更容易触发风控，建议手机退掉）
set -uo pipefail
cd "$(dirname "$0")" || exit 1
LABEL="com.local.qq-bridge"
UID_NUM="$(id -u)"
NEW_QQ="${1:-}"
KEEP_BRIDGE="${2:-}"
CFG_DIR="$HOME/qq-bridge-napcat/config"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

if ! [[ "${NEW_QQ}" =~ ^[1-9][0-9]{4,11}$ ]]; then
  echo "用法: ./switch-account.sh <新QQ号>" >&2; exit 1
fi

OLD_QQ=$(docker inspect napcat --format '{{json .Config.Cmd}}' 2>/dev/null | python3 -c "
import sys,json
try:
    a=json.load(sys.stdin) or []
    print(a[a.index('-q')+1] if '-q' in a else '')
except Exception: print('')
" 2>/dev/null)
echo "旧号: ${OLD_QQ:-未知}   新号: ${NEW_QQ}"

# ── 1. 备份现有配置 ────────────────────────────────────────────────────────────
say "1/6 备份 $(basename "$CFG_DIR")/"
STAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p "$HOME/qq-bridge-napcat/backup-$STAMP"
cp -a "$CFG_DIR" "$HOME/qq-bridge-napcat/backup-$STAMP/config"
echo "  → ~/qq-bridge-napcat/backup-$STAMP/config"

# ── 2. 桥接先摘下来 ────────────────────────────────────────────────────────────
if [ "${KEEP_BRIDGE}" != "--keep-bridge" ]; then
  say "2/6 停桥接（避免切号期间刷重连错误）"
  launchctl bootout "gui/${UID_NUM}/${LABEL}" 2>/dev/null || true
  pkill -f "node src/bridge.js" 2>/dev/null || true
  sleep 2
  echo "  已停"
else
  say "2/6 跳过停桥接（--keep-bridge）"
fi

# ── 3. 从旧号复制 network 段到新号 ─────────────────────────────────────────────
say "3/6 为新号预置 OneBot 网络配置（端口/token 沿用旧号）"
OLD_CFG="$CFG_DIR/onebot11_${OLD_QQ}.json"
NEW_CFG="$CFG_DIR/onebot11_${NEW_QQ}.json"
if [ ! -f "$OLD_CFG" ]; then
  echo "  ⚠️ 找不到 $OLD_CFG，无法复制 network 段；登录后请在 WebUI 里手动配 3000/3001" >&2
else
  python3 - "$OLD_CFG" "$NEW_CFG" <<'PY'
import json, sys
old_path, new_path = sys.argv[1], sys.argv[2]
old = json.load(open(old_path, encoding='utf-8'))
try:
    new = json.load(open(new_path, encoding='utf-8'))
except Exception:
    new = dict(old)          # 新号没有文件就整份沿用
new.setdefault('network', {})
for k in ('httpServers', 'websocketServers', 'httpSseServers', 'httpClients', 'websocketClients', 'plugins'):
    if old.get('network', {}).get(k):
        new['network'][k] = old['network'][k]
for k in ('musicSignUrl', 'enableLocalFile2Url', 'parseMultMsg', 'timeout'):
    if k in old:
        new.setdefault(k, old[k])
json.dump(new, open(new_path, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
srv = new['network'].get('httpServers') or [{}]
ws = new['network'].get('websocketServers') or [{}]
print(f"  写入 {new_path}")
print(f"    http :{srv[0].get('port')}  ws :{ws[0].get('port')}  token={str(srv[0].get('token'))[:8]}…")
PY
  # 触发读取账号级 napcat 设置（不存在时 NapCat 自己会生成默认值，这里先占位避免首启报错）
  [ -f "$CFG_DIR/napcat_${NEW_QQ}.json" ] || cp "$CFG_DIR/napcat_${OLD_QQ}.json" "$CFG_DIR/napcat_${NEW_QQ}.json" 2>/dev/null || true
fi

# ── 4. 用新号重建容器 ──────────────────────────────────────────────────────────
say "4/6 用新号重建容器（参数与原来一致：shm 1g、端口绑定、两个数据卷）"
docker stop napcat >/dev/null 2>&1
docker rm -f napcat >/dev/null 2>&1
docker run -d --name napcat \
  --restart unless-stopped \
  --shm-size=1g \
  -e NAPCAT_UID="$(id -u)" -e NAPCAT_GID="$(id -g)" -e TZ=Asia/Shanghai \
  -p 127.0.0.1:3000:3000 -p 127.0.0.1:3001:3001 -p 127.0.0.1:6099:6099 \
  -v "$HOME/qq-bridge-napcat/config":/app/napcat/config \
  -v "$HOME/qq-bridge-napcat/qqdata":/app/.config/QQ \
  mlikiowa/napcat-docker:latest -q "${NEW_QQ}" >/dev/null && echo "  容器已启动"

# ── 5. 取二维码等人扫 ──────────────────────────────────────────────────────────
say "5/6 抓取二维码（80 秒有效，扫一次就好）"
t0=$(date +%s); got=""
for i in $(seq 1 75); do
  sleep 2
  ts=$(docker exec napcat stat -c '%Y' /app/napcat/cache/qrcode.png 2>/dev/null || echo 0)
  if [ "$ts" != "0" ] && [ "$ts" -gt "$((t0 - 5))" ]; then
    docker cp napcat:/app/napcat/cache/qrcode.png ./qrcode.png >/dev/null 2>&1 && got=1 && break
  fi
done
if [ -n "$got" ]; then
  echo "  已保存 ./qrcode.png（$(docker exec napcat stat -c '%y' /app/napcat/cache/qrcode.png 2>/dev/null | cut -d. -f1)）"
  [ "$(uname -s)" = "Darwin" ] && open ./qrcode.png
else
  echo "  ⚠️ 没拿到二维码，稍后手动：docker cp napcat:/app/napcat/cache/qrcode.png ./qrcode.png"
fi

say "6/6 等待登录（最多 6 分钟；用新号扫码）"
TOKEN=$(python3 - "$NEW_CFG" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1],encoding='utf-8'))
    print(((d.get('network') or {}).get('httpServers') or [{}])[0].get('token') or '')
except Exception: print('')
PY
)
online=""
for i in $(seq 1 120); do
  st=$(curl -s -m 4 -X POST http://127.0.0.1:3000/get_status \
        -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' -d '{}' 2>/dev/null)
  case "$st" in *'"online":true'*) online=1; break;; esac
  sleep 3
done

if [ -z "$online" ]; then
  echo "  未检测到在线。重跑本脚本换一张码，或手动看 docker logs -f napcat" >&2
  [ "${KEEP_BRIDGE}" != "--keep-bridge" ] && \
    launchctl bootstrap "gui/${UID_NUM}" "$HOME/Library/LaunchAgents/${LABEL}.plist" 2>/dev/null
  exit 1
fi
echo "  ✅ 新号在线"
curl -s -m 6 -X POST http://127.0.0.1:3000/get_login_info \
  -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' -d '{}' | head -c 200; echo

if [ "${KEEP_BRIDGE}" != "--keep-bridge" ]; then
  launchctl bootstrap "gui/${UID_NUM}" "$HOME/Library/LaunchAgents/${LABEL}.plist" 2>/dev/null \
    || launchctl kickstart "gui/${UID_NUM}/${LABEL}" 2>/dev/null || true
  sleep 6
  echo "  桥接: $(pgrep -f 'node src/bridge.js' | wc -l | tr -d ' ') 个实例"
  tail -4 /tmp/qq-bridge.out.log | sed 's/^/    /'
fi

cat <<EOF

切号完成。剩下三件人肉事：
  1) 新号要**已经加爸爸(OWNER_QQ)、妈妈(PEER_QQ)为好友**，否则私聊发不出去
  2) 手机 QQ 上把新号退掉（多端同时在线更容易被风控盯）
  3) 观察 10 分钟：docker logs -f napcat | grep -E "KickedOffLine|账号状态"

回滚到旧号：./switch-account.sh ${OLD_QQ:-旧号}
配置备份在：~/qq-bridge-napcat/backup-${STAMP}
EOF
