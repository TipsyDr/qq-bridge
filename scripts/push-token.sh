#!/usr/bin/env bash
# 用现成的 PAT 把本地 fork 推到 TipsyDr/qq-bridge。
# 令牌从环境变量 GH_TOKEN 或文件 /tmp/.gh_tok 读，绝不写进仓库、不写进 remote URL。
#
#   GH_USER=TipsyDr GH_TOKEN=github_pat_xxx ./scripts/push-token.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

GH_USER="${GH_USER:-TipsyDr}"
REPO="${REPO:-qq-bridge}"
if [ -z "${GH_TOKEN:-}" ]; then
  GH_TOKEN=$(cat /tmp/.gh_tok 2>/dev/null || true)
fi
[ -n "$GH_TOKEN" ] || { echo "缺 GH_TOKEN" >&2; exit 1; }

api() { curl -s -m 30 -H "Authorization: Bearer ${GH_TOKEN}" -H "Accept: application/vnd.github+json" "$@"; }

# 1. 目标仓库必须已存在（fine-grained PAT 没有建仓权限，只能网页建）
code=$(api -o /dev/null -w '%{http_code}' "https://api.github.com/repos/${GH_USER}/${REPO}")
if [ "$code" = "404" ]; then
  cat >&2 <<EOF
目标仓库还不存在：https://github.com/${GH_USER}/${REPO}  (HTTP 404)

这个 fine-grained PAT 有仓库级 admin，但 GitHub 不允许它新建仓库，需要你在网页建一次：
  1) 打开 https://github.com/new?name=${REPO}
  2) Repository name 填 ${REPO}，Public，**不要**勾 README / .gitignore / license
  3) 点 Create repository
然后重跑本脚本。
EOF
  exit 2
fi
echo "[1/4] 目标仓库存在（HTTP ${code}）"

# 2. remote 布局：origin -> 自己的仓库，upstream -> 原作者
if git remote get-url origin 2>/dev/null | grep -q 'Derpyu520/qq-bridge'; then
  if git remote | grep -qx upstream; then
    git remote set-url origin "https://github.com/${GH_USER}/${REPO}.git"
  else
    git remote rename origin upstream
    git remote add origin "https://github.com/${GH_USER}/${REPO}.git"
  fi
elif ! git remote | grep -qx origin; then
  git remote add origin "https://github.com/${GH_USER}/${REPO}.git"
fi
git remote set-url origin "https://github.com/${GH_USER}/${REPO}.git"
if ! git remote | grep -qx upstream; then
  git remote add upstream https://github.com/Derpyu520/qq-bridge.git
fi
echo "[2/4] remote:"; git remote -v | sed 's/^/      /'

# 3. 推送（令牌只在这一次调用的 helper 里出现，不落盘）
echo "[3/4] push main …"
git -c credential.helper='' \
    -c "http.https://github.com/.extraheader=Authorization: Bearer ${GH_TOKEN}" \
    push origin main:main

# 4. 收尾
git branch --set-upstream-to=origin/main main >/dev/null 2>&1 || true
echo "[4/4] 完成"
git log --oneline -3
echo "  https://github.com/${GH_USER}/${REPO}"
