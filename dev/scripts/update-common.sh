#!/usr/bin/env bash
# dev/scripts/update-common.sh — shared functions for update pipeline.
# Sourced by update-input.sh, update-pkg.sh, update-combo.sh.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

WORKTREES_DIR="$PWD/.worktrees"
# `git worktree add` is not concurrency-safe: parallel invocations
# race on `.git/worktrees/<name>/commondir` creation. Serialize.
WORKTREE_LOCK="${WORKTREE_LOCK:-/run/user/$(id -u)/nix-update-worktree}"
REPORT_FILE="$PWD/.update-report.txt"
BRANCH=$(git rev-parse --abbrev-ref HEAD)

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
# After the script completes, the CI workflow pushes the branch
# and opens a PR (one PR per dependency, Renovate-style).
setup_worktree() {
  local name="$1"
  local wt="$WORKTREES_DIR/update-$name"
  local wt_branch="update/$name"

  if [ -d "$wt" ]; then
    # Clean any stuck git state from prior crashed runs
    git -C "$wt" cherry-pick --abort 2>/dev/null || true
    git -C "$wt" rebase --abort 2>/dev/null || true
    git -C "$wt" merge --abort 2>/dev/null || true
    # Discard modified tracked files (e.g. devenv.lock/flake.lock left
    # dirty from a prior crashed run) before the checkout — otherwise
    # `checkout -B` fails with "local changes would be overwritten".
    git -C "$wt" reset --hard HEAD >&2
    git -C "$wt" checkout -B "$wt_branch" "$BRANCH" >&2
    git -C "$wt" clean -fd >&2
  else
    mkdir -p "$WORKTREES_DIR"
    flock "$WORKTREE_LOCK" git worktree add -B "$wt_branch" "$wt" "$BRANCH" >&2
  fi

  # Symlink pre-commit config (devenv-generated, gitignored — worktrees don't have it).
  # Tools are nix store paths baked into the config, so no devenv activation needed.
  ln -sf "$PWD/.pre-commit-config.yaml" "$wt/.pre-commit-config.yaml"

  echo "$wt"
}

# Build verification. Runs the actual build to catch Mode C/D failures
# before PRs open — see docs/update-pipeline-transitive-hash-gap.md § Gap 5.
run_build() {
  "$@"
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
