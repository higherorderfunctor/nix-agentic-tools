#!/usr/bin/env bash
# dev/scripts/update-init.sh — pipeline initialization.
# Runs once before any update targets. Ensures clean state.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# shellcheck source-path=SCRIPTDIR
source "$(dirname "$0")/update-common.sh"

log_header "Pipeline init"

# Abort any stuck git state on the main branch
git cherry-pick --abort 2>/dev/null || true
git merge --abort 2>/dev/null || true
git rebase --abort 2>/dev/null || true

# Reap worktree registrations whose checkout dir is gone. $WORKTREES_DIR is
# an ephemeral temp root that a reboot / tmp cleaner / crashed run can
# wipe, leaving the registration in .git/worktrees/<name>/ stranded — a
# later `git worktree add` at the same path then fails. Pruning first lets
# setup_worktree's add path self-heal.
git worktree prune

# Remove orphaned worktrees whose target no longer exists in the current
# ninja file. Targets can disappear when packages or combo scripts are
# removed. Leaving orphans eats disk and confuses new contributors.
if [ -d "$WORKTREES_DIR" ] && [ -f ".update.ninja" ]; then
  for wt in "$WORKTREES_DIR"/update-*; do
    [ -d "$wt" ] || continue
    name="$(basename "$wt")"
    name="${name#update-}"
    if ! grep -q "update-${name}\b" .update.ninja 2>/dev/null; then
      echo "  Pruning orphaned worktree: $name"
      git worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
      git branch -D "update/$name" 2>/dev/null || true
    fi
  done
fi

# Detach worktrees so their branches can be deleted.
# setup_worktree will re-checkout the named branch.
if [ -d "$WORKTREES_DIR" ]; then
  for wt in "$WORKTREES_DIR"/update-*; do
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
