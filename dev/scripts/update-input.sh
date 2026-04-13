#!/usr/bin/env bash
# dev/scripts/update-input.sh <input-name>
# Update a single flake input in a worktree, verify build, merge back.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# shellcheck source-path=SCRIPTDIR
source "$(dirname "$0")/update-common.sh"

name="$1"
log_header "Input: $name"

wt=$(setup_worktree "$name")
version_file="$wt/.update-version"

# Phase 1: Update the input in the worktree
log_info "Updating flake input..."
if ! (
  cd "$wt"

  # Capture nix flake update output for version reporting
  nix flake update "$name" 2>&1 | tee "$version_file"

  # Regenerate devenv.yaml from updated flake.lock
  nix eval --raw --impure --expr 'import ./config/generate-devenv-yaml.nix {}' >devenv.yaml

  # Sync devenv.lock
  devenv update

  # Check if anything changed
  git add flake.lock devenv.yaml devenv.lock
  if git diff --staged --quiet; then
    exit 0
  fi

  # Phase 2: Build verification (skipped in CI mode)
  run_build nix run --inputs-from . nix-fast-build -- --skip-cached --no-nom --no-link --flake ".#packages.$(nix eval --impure --raw --expr 'builtins.currentSystem')"

  # Phase 3: Commit only after build passes (or skipped in CI)
  git commit -m "chore: update input $name"
); then
  version_detail=$(parse_input_version "$version_file" "$name")
  report_held_back "$name" "update or build failed" "$version_detail"
  exit 0
fi

# Extract version info
version_detail=$(parse_input_version "$version_file" "$name")

# Check if the worktree actually made commits
wt_head=$(git -C "$wt" rev-parse HEAD)
base_head=$(git rev-parse "$BRANCH")
if [ "$wt_head" = "$base_head" ]; then
  report_unchanged "$name"
  exit 0
fi

merge_to_branch "$wt" "$name" || rc=$?
rc=${rc:-0}
if [ "$rc" -eq 1 ]; then
  report_held_back "$name" "cherry-pick conflict" "$version_detail"
  exit 0
elif [ "$rc" -eq 2 ]; then
  report_unchanged "$name"
  exit 0
fi
report_updated "$name" "$version_detail"
