#!/usr/bin/env bash
# 把 fork 推到自己的 GitHub 仓库。需要两样东西：
#   GH_USER  —— 你的 GitHub 用户名（不是邮箱）
#   GH_TOKEN —— 有 repo 权限的 Personal Access Token（classic 勾 repo，或 fine-grained 给 Contents: R/W）
#
# 用法：
#   GH_USER=xxx GH_TOKEN=ghp_xxx ./scripts/push-fork.sh
#   GH_USER=xxx ./scripts/push-fork.sh          # 已配好 SSH key 时可只给用户名
#
# 幂等：重复跑不会重复加 remote，fork 已存在时直接推送。
set -euo pipefail

REPO_SLUG="Derpyu520/qq-bridge"
UPSTREAM_URL="https://github.com/${REPO_SLUG}.git"

cd "$(dirname "$0")/.."

GH_USER="${GH_USER:-}"
GH_TOKEN="${GH_TOKEN:-${GH_TOKEN_PAT:-}}"

if [ -z "$GH_USER" ]; then
  echo "缺 GH_USER。你的 GitHub 用户名（github.com/<这里> 那一段），不是邮箱。" >&2
  exit 1
fi

# 0. 先确认用户名真实存在，避免建出一个 404 的 remote
if [ -n "$GH_TOKEN" ]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${GH_TOKEN}" \
    "https://api.github.com/users/${GH_USER}")
else
  code=$(curl -s -o /dev/null -w '%{http_code}' -L "https://github.com/${GH_USER}")
fi
if [ "$code" = "404" ]; then
  echo "GitHub 上不存在用户 ${GH_USER}（404）。换个用户名，别用邮箱。" >&2
  exit 1
fi
echo "[1/5] 用户 ${GH_USER} 存在（HTTP ${code}）"

# 1. 建 fork（已存在会被 API 当成功处理）
if [ -n "$GH_TOKEN" ]; then
  echo "[2/5] 通过 API 创建/确认 fork …"
  curl -s -X POST -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${REPO_SLUG}/forks" \
    -o /tmp/fork-resp.json -w '  HTTP %{http_code}\n' || true
  if grep -q '"message"' /tmp/fork-resp.json 2>/dev/null; then
    head -c 300 /tmp/fork-resp.json; echo
  fi
else
  echo "[2/5] 无 token，跳过 API 建 fork。请先在网页点一次 Fork："
  echo "      https://github.com/${REPO_SLUG}/fork"
  read -r -p "      建好了按回车继续… " _
fi

# 2. remote 改名：原 origin -> upstream，新 origin 指向自己的 fork
if git remote get-url origin 2>/dev/null | grep -q "$REPO_SLUG"; then
  if git remote | grep -qx upstream; then
    git remote set-url origin "https://github.com/${GH_USER}/qq-bridge.git"
  else
    git remote rename origin upstream
    git remote add origin "https://github.com/${GH_USER}/qq-bridge.git"
  fi
fi
git remote set-url origin "https://github.com/${GH_USER}/qq-bridge.git"
echo "[3/5] remote:"; git remote -v | sed 's/^/      /'

# 3. 推送
echo "[4/5] 推送 main …"
if [ -n "$GH_TOKEN" ]; then
  git push "https://${GH_USER}:${GH_TOKEN}@github.com/${GH_USER}/qq-bridge.git" main:main
  git branch --set-upstream-to=origin/main main >/dev/null 2>&1 || true
else
  git push -u origin main
fi

echo "[5/5] 完成："
git log --oneline -1
echo "  https://github.com/${GH_USER}/qq-bridge"
