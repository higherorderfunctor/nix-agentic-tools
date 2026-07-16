#!/usr/bin/env bash
# dev/scripts/update-common.sh — shared functions for update pipeline.
# Sourced by update-input.sh, update-pkg.sh, update-combo.sh.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

# Deterministic overlay-file resolution (resolve_overlay_file).
# shellcheck source=dev/scripts/resolve-overlay-file.sh
source "$(dirname "${BASH_SOURCE[0]}")/resolve-overlay-file.sh"

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

# nix-fast-build wrapper that gates on four independent signals.
#
# Upstream bug: nix-fast-build's async_main `finally: stack.aclose()` can
# swallow non-zero exit on the build-failure path, so per-build failures
# sometimes silently exit 0. Effect: a broken peer package lets nixpkgs
# (or any input/package update) report as UPDATED instead of HELD BACK.
#
# Defense in depth — fail if ANY of these tripwires fire:
#   1. nix-fast-build's own exit code is non-zero
#   2. The JSON result file shows any `success: false` (or is empty/missing)
#   3. nix-fast-build's stderr contains
#      `ERROR:nix_fast_build:BUILD: N successes, M failures` with M > 0 —
#      the consistent signal observed in CI run 26473689694 when (1) and
#      (2) both missed.
#   4. nix-fast-build's stderr contains
#      `ERROR:nix_fast_build:EVAL: N successes, M failures` with M > 0 —
#      eval-time throws are invisible to gates 1-3.
#
# On failure, forensic data (result file + stderr capture) is preserved
# under `.update-logs/` and surfaced by the Diagnostic dump workflow step.
#
# The JSON shape emitted by nix-fast-build (nix_fast_build/__init__.py
# `dump_json`) is:
#   {"results": [{"attr": "...", "success": bool, "error": "..." | null, ...}]}
#
# Usage: run_nfb_build nix run --inputs-from . nix-fast-build -- ...
run_nfb_build() {
  local rf stderr_log exit_code=0 failed=0
  mkdir -p "$PWD/.update-logs"
  rf=$(mktemp -p "$PWD/.update-logs" --suffix=.json nfb-result-XXXXXX) || return 1
  stderr_log=$(mktemp -p "$PWD/.update-logs" --suffix=.log nfb-stderr-XXXXXX) || {
    rm -f "$rf"
    return 1
  }

  # Buffered stderr capture (not `2> >(tee ...)`): bash process
  # substitution offers no synchronization with the parent shell, so the
  # tee writer may still be flushing when gate 3 greps the file. The
  # buffered form `2> file` then `cat file >&2` is deterministic — we
  # only lose real-time stderr streaming, which the caller already
  # tees through `2>&1 | tee .update-logs/final-build.log` anyway.
  #
  # `|| exit_code=$?` localizes errexit suppression to this single call
  # (NOT a blanket `set +e`) — we want to inspect the exit code AND
  # continue to the JSON/stderr gates regardless.
  "$@" --result-file "$rf" --result-format json \
    2>"$stderr_log" || exit_code=$?
  cat "$stderr_log" >&2

  # Gate 1: nix-fast-build's own exit code.
  if [ "$exit_code" -ne 0 ]; then
    log_failure "nix-fast-build exited non-zero ($exit_code)"
    failed=1
  fi

  # Gate 2: JSON result file. Empty/missing file is also a failure (we
  # asked for one; not getting one means the build verification was
  # incomplete and we should not trust it).
  if [ ! -s "$rf" ]; then
    log_failure "nix-fast-build wrote no result file (expected $rf)"
    failed=1
  elif ! jq -e '.results | all(.success)' "$rf" >/dev/null 2>&1; then
    log_failure "nix-fast-build result file shows per-build failures:"
    jq -r '.results[] | select(.success | not) | "    \(.attr): \(.error // "<no error message>")"' \
      "$rf" >&2 || true
    failed=1
  fi

  # Gate 3: stderr fallback. Observed in CI run 26473689694 — the JSON
  # gate missed a copilot-cli build failure but this stderr line was
  # present. nix-fast-build emits it consistently when builds fail, even
  # when its own exit code and JSON output are misleading.
  if grep -qE "ERROR:nix_fast_build:BUILD: [0-9]+ successes, [1-9][0-9]* failures" "$stderr_log"; then
    log_failure "nix-fast-build stderr reports build failures:"
    grep -E "BUILD: [0-9]+ successes|Failed attributes:" "$stderr_log" >&2 || true
    failed=1
  fi

  # Gate 4: evaluation failures. nix-fast-build reports eval-time errors on a
  # separate line from build failures. An attribute that throws during
  # evaluation (e.g. an input bump that breaks a package's eval) never becomes
  # a build, so it produces no `success: false` result entry (gate 2) and does
  # not increment the BUILD failure count (gate 3): it is invisible to gates
  # 1-3. nix-fast-build emits a distinct line for it:
  #   ERROR:nix_fast_build:EVAL: N successes, M failures
  # Observed when a nixpkgs bump broke effect-mcp's fetchPnpmDeps eval, yet the
  # nixpkgs update still shipped as UPDATED instead of HELD BACK.
  if grep -qE "ERROR:nix_fast_build:EVAL: [0-9]+ successes, [1-9][0-9]* failures" "$stderr_log"; then
    log_failure "nix-fast-build stderr reports evaluation failures:"
    grep -E "EVAL: [0-9]+ successes|Failed attributes:" "$stderr_log" >&2 || true
    failed=1
  fi

  if [ "$failed" -eq 1 ]; then
    log_failure "(forensic data preserved: $rf, $stderr_log)"
    return 1
  fi

  rm -f "$rf" "$stderr_log"
  return 0
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
