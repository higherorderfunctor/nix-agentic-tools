#!/usr/bin/env bash
# dev/scripts/update-lock.sh <name> <flake-dir>
# Refresh a dev-only fixture flake's own lock (checks/<concern>/flake.lock) in a
# worktree. The fixture's own CI job, a required context, is the build
# verification.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# shellcheck source-path=SCRIPTDIR
source "$(dirname "$0")/update-common.sh"

name="$1"
flake_dir="$2"
log_header "Lock: $name ($flake_dir)"

wt=$(setup_worktree "$name")
trap 'teardown_worktree "$wt"' EXIT
version_file="$wt/.update-version"

# Standalone subshell, never an `if !` condition: see "Target subshell shape"
# in update-common.sh and checks/shell/target-subshell-shape.nix.
target_rc=0
set +e
(
  set -euETo pipefail
  shopt -s inherit_errexit 2>/dev/null || :

  cd "$wt"

  if ! nix flake update --flake "./$flake_dir" 2>&1 | tee "$version_file"; then
    pipe=("${PIPESTATUS[@]}")
    log_failure "nix flake update failed (nix=${pipe[0]} tee=${pipe[1]})"
    exit 1
  fi
  if ! git add -- "$flake_dir/flake.lock"; then
    log_failure "git add failed"
    exit 1
  fi
  if git_diff_quiet diff --staged; then
    exit 0
  fi
  if ! git commit -m "chore: update lock $name"; then
    log_failure "git commit failed"
    exit 1
  fi
)
target_rc=$?
set -e

version_detail=""
if [ -f "$version_file" ]; then
  version_detail=$(grep -oP "Updated input '\K[^']+" "$version_file" | paste -sd',' || true)
fi

if [ "$target_rc" -ne 0 ]; then
  report_held_back "$name" "lock update failed" "$version_detail"
  exit 0
fi

if [ "$(git -C "$wt" rev-parse HEAD)" = "$(git rev-parse "$BRANCH")" ]; then
  report_unchanged "$name"
  exit 0
fi

log_success "$name: branch update/$name ready for PR"
report_updated "$name" "$version_detail"
