#!/bin/sh
# 取 NapCat 当前二维码并用系统看图器打开（NapCat 约 80 秒自动刷新一次，随时可重跑）
cd "$(dirname "$0")" || exit 1
docker cp napcat:/app/napcat/cache/qrcode.png ./qrcode.png >/dev/null 2>&1 || {
  echo "取二维码失败：容器 napcat 是否在运行？(docker ps)" >&2; exit 1; }
echo "已更新 ./qrcode.png（容器内生成于 $(docker exec napcat stat -c '%y' /app/napcat/cache/qrcode.png 2>/dev/null | cut -d. -f1)）"
[ "$(uname -s)" = "Darwin" ] && open ./qrcode.png
