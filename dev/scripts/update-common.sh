#!/usr/bin/env bash
# dev/scripts/update-common.sh — shared functions for update pipeline.
# Sourced by update-input.sh, update-pkg.sh, update-combo.sh.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

WORKTREES_DIR=".worktrees"
MERGE_LOCK="/run/user/$(id -u)/nix-update-merge"
REPORT_FILE=".update-report.txt"
BRANCH=$(git rev-parse --abbrev-ref HEAD)

# ── ANSI colors (forced on — ninja passes through when stdout is a terminal) ──
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

# GitHub token for nix-update rate limits
if [ -z "${GITHUB_TOKEN:-}" ] && command -v gh &>/dev/null; then
	GITHUB_TOKEN=$(gh auth token 2>/dev/null) || true
	[ -n "${GITHUB_TOKEN:-}" ] && export GITHUB_TOKEN
fi

# ── Output helpers ────────────────────────────────────────────────────────────

log_header() {
	echo "${BOLD}${CYAN}══════════════════════════════════════════════════${RESET}"
	echo "${BOLD}${CYAN}  $1${RESET}"
	echo "${BOLD}${CYAN}══════════════════════════════════════════════════${RESET}"
}

log_success() {
	echo "${GREEN}  ✓ $1${RESET}"
}

log_failure() {
	echo "${RED}  ✗ $1${RESET}" >&2
}

log_info() {
	echo "${YELLOW}  … $1${RESET}"
}

# ── Worktree management ──────────────────────────────────────────────────────

# Create or reset a worktree at the current branch HEAD.
# Stores the base commit so merge_to_branch can cherry-pick the full range.
setup_worktree() {
	local name="$1"
	local wt="$WORKTREES_DIR/update-$name"
	local base

	base=$(git rev-parse HEAD)

	if [ -d "$wt" ]; then
		git -C "$wt" checkout --detach HEAD >&2 || true
		git -C "$wt" reset --hard "$BRANCH" >&2
	else
		mkdir -p "$WORKTREES_DIR"
		git worktree add --detach "$wt" "$BRANCH" >&2
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
		log_info "$name: no new commits to merge"
		return 0
	fi

	# flock serializes cherry-picks from parallel targets
	# Cherry-pick the full range of commits made in the worktree
	flock "$MERGE_LOCK" git cherry-pick "$base".."$wt_head"
	log_success "$name: cherry-picked to $BRANCH"
}

# ── Report helpers ────────────────────────────────────────────────────────────
# Every target must write exactly one report entry before exiting.

report_updated() {
	local name="$1"
	local detail="${2:-}"
	echo "UPDATED: $name ${detail}" >>"$REPORT_FILE"
	log_success "UPDATED: $name ${detail}"
}

report_unchanged() {
	local name="$1"
	echo "NO UPDATES: $name (already up to date)" >>"$REPORT_FILE"
	log_info "NO UPDATES: $name (already up to date)"
}

report_held_back() {
	local name="$1"
	local reason="$2"
	echo "HELD BACK: $name ($reason)" >>"$REPORT_FILE"
	log_failure "HELD BACK: $name — $reason"
}
