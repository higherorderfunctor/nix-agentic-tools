#!/usr/bin/env bash
# dev/scripts/update-common.sh — shared functions for update pipeline.
# Sourced by update-input.sh, update-pkg.sh, update-combo.sh.
#
# CI mode (UPDATE_CI=1): skip builds, skip cherry-pick. Worktree
# branches are pushed by the CI workflow after ninja completes.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

WORKTREES_DIR="$PWD/.worktrees"
MERGE_LOCK="${MERGE_LOCK:-/run/user/$(id -u)/nix-update-merge}"
REPORT_FILE="$PWD/.update-report.txt"
BRANCH=$(git rev-parse --abbrev-ref HEAD)
CI_MODE="${UPDATE_CI:-}"

# Force color output from subcommands (ninja buffers output, tools lose TTY detection)
export CLICOLOR_FORCE=1

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

# Create or reset a worktree on a named branch (update/<name>).
# Both local and CI use the same branch strategy. The difference is
# what happens after: local builds + cherry-picks, CI just leaves the branch.
setup_worktree() {
  local name="$1"
  local wt="$WORKTREES_DIR/update-$name"
  local wt_branch="update/$name"

  if [ -d "$wt" ]; then
    # Clean any stuck git state from prior crashed runs
    git -C "$wt" cherry-pick --abort 2>/dev/null || true
    git -C "$wt" rebase --abort 2>/dev/null || true
    git -C "$wt" merge --abort 2>/dev/null || true
    git -C "$wt" checkout -B "$wt_branch" "$BRANCH" >&2
    git -C "$wt" clean -fd >&2
  else
    mkdir -p "$WORKTREES_DIR"
    git worktree add -B "$wt_branch" "$wt" "$BRANCH" >&2
  fi

  # Symlink pre-commit config (devenv-generated, gitignored — worktrees don't have it).
  # Tools are nix store paths baked into the config, so no devenv activation needed.
  ln -sf "$PWD/.pre-commit-config.yaml" "$wt/.pre-commit-config.yaml"

  echo "$wt"
}

# Build verification. In CI mode, prefetch sources instead of full build.
# Sources must be in cachix for CI eval (IFD: readFile on fetchFromGitHub).
run_build() {
  if [ -n "$CI_MODE" ]; then
    log_info "CI mode: skipping full build (PR pipeline validates)"
    return 0
  fi
  "$@"
}

# Prefetch package sources so they're in cachix for CI eval.
# Only needed in CI mode — local builds realize sources as a side effect.
prefetch_sources() {
  if [ -z "$CI_MODE" ]; then
    return 0
  fi
  for pkg in "$@"; do
    log_info "Prefetching source: $pkg"
    nix build ".#$pkg.src" --no-link 2>/dev/null || true
  done
}

# Cherry-pick worktree commits to main branch. No-op in CI mode.
# In CI, the worktree branch is pushed by the workflow after ninja completes.
merge_to_branch() {
  local wt="$1"
  local name="$2"
  local wt_head
  local base_head

  wt_head=$(git -C "$wt" rev-parse HEAD)
  base_head=$(git rev-parse "$BRANCH")

  # Only merge if worktree has new commits vs the base branch
  if [ "$wt_head" = "$base_head" ]; then
    log_info "$name: no new commits to merge"
    return 0
  fi

  # CI mode: branch exists, will be pushed by workflow
  if [ -n "$CI_MODE" ]; then
    log_success "$name: branch update/$name ready for PR"
    return 0
  fi

  # Local mode: cherry-pick to main branch
  # flock serializes cherry-picks from parallel targets.
  # Empty cherry-picks (change already on branch) are skipped, not failures.
  # Returns: 0 = merged, 2 = already on branch (empty), 1 = conflict
  if ! flock "$MERGE_LOCK" git cherry-pick "$base_head".."$wt_head"; then
    if git diff --staged --quiet 2>/dev/null; then
      # Empty cherry-pick — change already on branch
      git cherry-pick --skip 2>/dev/null || git cherry-pick --abort 2>/dev/null || true
      log_info "$name: already on branch (skipped)"
      return 2
    else
      # Real conflict
      git cherry-pick --abort 2>/dev/null || true
      log_failure "$name: cherry-pick conflict"
      return 1
    fi
  fi
  log_success "$name: cherry-picked to $BRANCH"
}

# ── Version parsing ───────────────────────────────────────────────────────────

# Parse nix-update output for "Update X -> Y" lines
parse_pkg_version() {
  local version_file="$1"
  if [ -f "$version_file" ]; then
    grep -oP 'Update \K\S+ -> \S+' "$version_file" | paste -sd', ' || true
  fi
}

# Parse nix flake update output for "Updated input 'name'" lines
# Extracts the date portion: (YYYY-MM-DD) → (YYYY-MM-DD)
parse_input_version() {
  local version_file="$1"
  local name="$2"
  if [ -f "$version_file" ]; then
    grep "Updated input '$name'" "$version_file" |
      grep -oP '\(\K[0-9-]+(?=\))' |
      paste -sd' → ' || true
  fi
}

# ── Report helpers ────────────────────────────────────────────────────────────
# Every target must write exactly one report entry before exiting.
# Format: STATUS: name [| version_detail] [(reason)]

report_updated() {
  local name="$1"
  local detail="${2:-}"
  local line="UPDATED: $name"
  [ -n "$detail" ] && line="$line | $detail"
  echo "$line" >>"$REPORT_FILE"
  log_success "$line"
}

report_unchanged() {
  local name="$1"
  echo "NO UPDATES: $name" >>"$REPORT_FILE"
  log_info "NO UPDATES: $name"
}

report_held_back() {
  local name="$1"
  local reason="$2"
  local detail="${3:-}"
  local line="HELD BACK: $name ($reason)"
  [ -n "$detail" ] && line="HELD BACK: $name | $detail ($reason)"
  echo "$line" >>"$REPORT_FILE"
  log_failure "$line"
}
