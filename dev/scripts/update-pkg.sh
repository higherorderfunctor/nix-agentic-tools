#!/usr/bin/env bash
# dev/scripts/update-pkg.sh <package-name> [extra-nix-update-flags...]
# Update a single package in a worktree, verify build, merge back.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# shellcheck source=dev/scripts/update-common.sh
source "$(dirname "$0")/update-common.sh"

name="$1"
shift
extra_flags="$*"
system=$(nix eval --impure --raw --expr 'builtins.currentSystem')

log_header "Package: $name"

wt=$(setup_worktree "$name")

# Phase 1: Update (--no-commit: we commit after build validation)
log_info "Running nix-update..."
if ! (
	cd "$wt"

	# shellcheck disable=SC2086
	nix run --inputs-from . nix-update -- --flake "$name" --system "$system" $extra_flags

	# Check if nix-update made any changes
	if git -C "$wt" diff --quiet && git -C "$wt" diff --staged --quiet; then
		exit 0
	fi

	# Phase 2: Build verification (runs derivation-level tests)
	# TODO: additional checks, smoke tests (future validation phase)
	nix build ".#$name" --no-link --log-format bar-with-logs

	# Phase 3: Commit only after build passes
	git -C "$wt" add -A
	git -C "$wt" commit -m "chore(overlays): update $name"
); then
	report_held_back "$name" "nix-update or build failed"
	exit 0
fi

# Check if the worktree actually made commits
wt_head=$(git -C "$wt" rev-parse HEAD)
base=$(cat "$wt/.update-base")
if [ "$wt_head" = "$base" ]; then
	report_unchanged "$name"
	exit 0
fi

merge_to_branch "$wt" "$name"
report_updated "$name"
