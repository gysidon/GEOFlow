#!/usr/bin/env bash
#
# 同步上游（yaojingang/GEOFlow）到当前 fork 仓库。
#
# 流程：fetch upstream → 检查是否有新提交 → merge → 推送到 origin。
# 使用 merge 而非 rebase：保持线性历史，后续同步上游时冲突面小。
# 检测到冲突会自动回滚（git merge --abort）并退出，不会留下半拉倒的状态。
#
# 用法：
#   bash deploy-scripts/fork-sync-upstream.sh              # 同步并推送
#   bash deploy-scripts/fork-sync-upstream.sh --dry-run    # 只看差异，不合并
#   BRANCH=custom bash deploy-scripts/fork-sync-upstream.sh # 指定工作分支
#
# 环境变量：
#   UPSTREAM_REPO  上游仓库地址，默认 git@github.com:yaojingang/GEOFlow.git
#   BRANCH         工作分支，默认 custom
#   REMOTE_BRANCH  推送目标分支，默认与 BRANCH 相同
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

UPSTREAM_REPO="${UPSTREAM_REPO:-git@github.com:yaojingang/GEOFlow.git}"
BRANCH="${BRANCH:-custom}"
REMOTE_BRANCH="${REMOTE_BRANCH:-$BRANCH}"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

cd "${PROJECT_DIR}"

log() { printf '\033[1;34m[sync]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

git rev-parse --git-dir >/dev/null 2>&1 || fail "当前目录不是 Git 仓库。"

# ---------------------------------------------------------------------------
# 1. 确认远端配置
# ---------------------------------------------------------------------------
if ! git remote get-url upstream >/dev/null 2>&1; then
  log "添加 upstream 远端: ${UPSTREAM_REPO}"
  git remote add upstream "${UPSTREAM_REPO}"
else
  current_upstream="$(git remote get-url upstream)"
  if [[ "${current_upstream}" != "${UPSTREAM_REPO}" ]]; then
    log "更新 upstream 地址: ${current_upstream} -> ${UPSTREAM_REPO}"
    git remote set-url upstream "${UPSTREAM_REPO}"
  fi
fi

if ! git remote get-url origin >/dev/null 2>&1; then
  fail "缺少 origin 远端。请先执行: git remote add origin git@github.com:<你的账号>/GEOFlow.git"
fi

# ---------------------------------------------------------------------------
# 2. 拉取上游
# ---------------------------------------------------------------------------
# GitHub 在弱网环境下 fetch 容易中断，这里做多策略重试：
#   ① 标准 fetch（完整历史）
#   ② 浅 fetch（--depth，降低传输量）
#   ③ 浅 fetch 单分支（最小传输量）
fetch_upstream() {
  local attempt
  for attempt in 1 2 3; do
    log "拉取上游（第 ${attempt}/3 次尝试）: ${UPSTREAM_REPO}"
    if git fetch upstream --tags --prune; then
      return 0
    fi
    warn "第 ${attempt} 次拉取失败，10 秒后重试。"
    sleep 10
  done

  log "改用浅克隆模式拉取（传输量更小，适合弱网）"
  if git fetch --depth=50 upstream main 2>/dev/null \
     || git fetch --depth=10 upstream main 2>/dev/null; then
    warn "已用浅模式拉到上游，合并历史可能不完整。恢复网络后建议重新完整同步。"
    return 0
  fi

  fail "拉取上游失败。检查网络或 SSH 密钥配置（ssh -T git@github.com）。"
}

fetch_upstream

upstream_ref="upstream/main"
if ! git rev-parse --verify "${upstream_ref}" >/dev/null 2>&1; then
  upstream_ref="upstream/master"
  git rev-parse --verify "${upstream_ref}" >/dev/null 2>&1 || fail "上游没有 main 或 master 分支。"
fi

upstream_sha="$(git rev-parse "${upstream_ref}")"
log "上游最新提交: ${upstream_sha:0:12}  $(git log -1 --format=%s "${upstream_ref}")"

# ---------------------------------------------------------------------------
# 3. 确认工作分支
# ---------------------------------------------------------------------------
if ! git rev-parse --verify "origin/${BRANCH}" >/dev/null 2>&1 \
   && ! git rev-parse --verify "${BRANCH}" >/dev/null 2>&1; then
  log "创建分支 ${BRANCH}（基于 ${upstream_ref}）"
  git checkout -b "${BRANCH}" "${upstream_ref}"
elif git rev-parse --verify "${BRANCH}" >/dev/null 2>&1; then
  git checkout "${BRANCH}"
else
  log "检出远程分支 ${BRANCH}"
  git checkout -b "${BRANCH}" --track "origin/${BRANCH}"
fi

# ---------------------------------------------------------------------------
# 4. 计算差异
# ---------------------------------------------------------------------------
if git merge-base --is-ancestor "${upstream_ref}" HEAD 2>/dev/null; then
  log "已是最新，无需合并。"
  exit 0
fi

behind="$(git rev-list --count "HEAD..${upstream_ref}")"
ahead="$(git rev-list --count "${upstream_ref}..HEAD")"
log "待合并上游提交: ${behind} 个；本地独有提交: ${ahead} 个"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  log "--dry-run 模式，列出将合并的提交："
  git log --oneline --no-decorate "HEAD..${upstream_ref}" | sed 's/^/    /'
  log "不执行合并。移除 --dry-run 即可实际同步。"
  exit 0
fi

# ---------------------------------------------------------------------------
# 5. 合并（冲突时自动回滚）
# ---------------------------------------------------------------------------
log "合并 ${upstream_ref} -> ${BRANCH}"
if ! git merge --no-edit --no-commit "${upstream_ref}"; then
  warn "合并产生冲突，已自动回滚。可查看：git merge ${upstream_ref} 手动处理。"
  git merge --abort 2>/dev/null || true
  fail "同步失败：存在冲突。请手动解决后重试。"
fi

if git diff --cached --quiet; then
  log "合并结果为空（无实际变更），保持原状。"
else
  git commit -m "chore(sync): 合并上游 ${upstream_ref} @ ${upstream_sha:0:12}"
  log "已提交合并结果。"
fi

# ---------------------------------------------------------------------------
# 6. 推送
# ---------------------------------------------------------------------------
log "推送到 origin/${REMOTE_BRANCH}"
if git push origin "HEAD:refs/heads/${REMOTE_BRANCH}"; then
  log "推送完成。"
else
  fail "推送失败。若远程分支存在且历史不一致，用: git push --force-with-lease origin HEAD:${REMOTE_BRANCH}"
fi

log "当前分支状态:"
git log --oneline -3 | sed 's/^/    /'
