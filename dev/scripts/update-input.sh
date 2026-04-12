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

# Phase 1: Update the input in the worktree
log_info "Updating flake input..."
if ! (
	cd "$wt"
	nix flake update "$name"

	# Regenerate devenv.yaml from updated flake.lock
	nix eval --raw --impure --expr 'import ./config/generate-devenv-yaml.nix {}' >devenv.yaml

	# Sync devenv.lock
	devenv update

	# Check if anything changed
	git add flake.lock devenv.yaml devenv.lock
	if git diff --staged --quiet; then
		exit 0
	fi

	# Phase 2: Build verification (runs derivation-level tests)
	# TODO: additional checks, smoke tests (future validation phase)
	nix run --inputs-from . nix-fast-build -- --skip-cached --no-nom --no-link --flake ".#packages.$(nix eval --impure --raw --expr 'builtins.currentSystem')"

	# Phase 3: Commit only after build passes
	git commit -m "chore: update input $name"
); then
	report_held_back "$name" "update or build failed"
	exit 0
fi

# Check if the worktree actually made commits
wt_head=$(git -C "$wt" rev-parse HEAD)
base=$(cat "$wt/.update-base")
if [ "$wt_head" = "$base" ]; then
	report_unchanged "$name"
	exit 0
fi

merge_to_branch "$wt" "$name" || rc=$?
rc=${rc:-0}
if [ "$rc" -eq 1 ]; then
	report_held_back "$name" "cherry-pick conflict"
	exit 0
elif [ "$rc" -eq 2 ]; then
	report_unchanged "$name"
	exit 0
fi
report_updated "$name"
