#!/usr/bin/env bash
# scripts/update-common.sh — shared functions for update pipeline.
# Sourced by update-input.sh, update-pkg.sh, update-combo.sh.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

WORKTREES_DIR=".worktrees"
MERGE_LOCK="/run/user/$(id -u)/nix-update-merge"
REPORT_FILE=".update-report.txt"
BRANCH=$(git rev-parse --abbrev-ref HEAD)

# GitHub token for nix-update rate limits
if [ -z "${GITHUB_TOKEN:-}" ] && command -v gh &>/dev/null; then
	GITHUB_TOKEN=$(gh auth token 2>/dev/null) || true
	[ -n "${GITHUB_TOKEN:-}" ] && export GITHUB_TOKEN
fi

# Create or reset a worktree at the current branch HEAD.
# Stores the base commit so merge_to_branch can cherry-pick the full range.
setup_worktree() {
	local name="$1"
	local wt="$WORKTREES_DIR/update-$name"
	local base

	base=$(git rev-parse HEAD)

	if [ -d "$wt" ]; then
		git -C "$wt" checkout --detach HEAD 2>/dev/null || true
		git -C "$wt" reset --hard "$BRANCH" 2>/dev/null
	else
		mkdir -p "$WORKTREES_DIR"
		git worktree add --detach "$wt" "$BRANCH" 2>/dev/null
	fi

	# Stash base commit for range cherry-pick
	echo "$base" >"$wt/.update-base"
	echo "$wt"
}

# Acquire merge lock, cherry-pick all worktree commits to main branch, release.
# Handles targets that produce multiple commits (e.g., combo updates).
merge_to_branch() {
	local wt="$1"
	local name="$2"
	local wt_head
	local base

	wt_head=$(git -C "$wt" rev-parse HEAD)
	base=$(cat "$wt/.update-base")

	# Only merge if worktree has new commits
	if [ "$wt_head" = "$base" ]; then
		echo "$name: no changes"
		return 0
	fi

	# flock serializes cherry-picks from parallel targets
	# Cherry-pick the full range of commits made in the worktree
	flock "$MERGE_LOCK" git cherry-pick "$base".."$wt_head"
	echo "$name: merged"
}

# Report success
report_updated() {
	local name="$1"
	local detail="${2:-}"
	echo "UPDATED: $name ${detail}" >>"$REPORT_FILE"
}

# Report skip/failure
report_skipped() {
	local name="$1"
	local reason="$2"
	echo "HELD BACK: $name ($reason)" >>"$REPORT_FILE"
	echo "WARNING: $name held back — $reason" >&2
}
