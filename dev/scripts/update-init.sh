#!/usr/bin/env bash
# dev/scripts/update-init.sh — pipeline initialization.
# Runs once before any update targets. Ensures clean state.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

# ── ANSI colors ──────────────────────────────────────────────────────────────
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

echo "${BOLD}${CYAN}══════════════════════════════════════════════════${RESET}"
echo "${BOLD}${CYAN}  Pipeline init${RESET}"
echo "${BOLD}${CYAN}══════════════════════════════════════════════════${RESET}"

# Abort any stuck git state on the main branch
git cherry-pick --abort 2>/dev/null || true
git merge --abort 2>/dev/null || true
git rebase --abort 2>/dev/null || true

# Remove orphaned worktrees whose target no longer exists in the
# current ninja file. Targets can disappear when packages or combo
# scripts are removed (e.g., any-buddy/claude-code combo target).
# Leaving orphans around eats disk and confuses new contributors.
if [ -d ".worktrees" ] && [ -f ".update.ninja" ]; then
  for wt in .worktrees/update-*; do
    [ -d "$wt" ] || continue
    name="${wt#.worktrees/update-}"
    if ! grep -q "update-${name}\b" .update.ninja 2>/dev/null; then
      echo "  Pruning orphaned worktree: $name"
      git worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
      git branch -D "update/$name" 2>/dev/null || true
    fi
  done
fi

# Detach worktrees so their branches can be deleted.
# setup_worktree will re-checkout the named branch.
if [ -d ".worktrees" ]; then
  for wt in .worktrees/update-*; do
    [ -d "$wt" ] && git -C "$wt" checkout --detach HEAD 2>/dev/null || true
  done
fi

# Clean up stale update/* local branches from prior runs
git branch --list 'update/*' | while read -r branch; do
  branch=$(echo "$branch" | tr -d ' *+')
  git branch -D "$branch" 2>/dev/null || true
done

# Clear report from prior runs
rm -f .update-report.txt

echo "  Ready."
