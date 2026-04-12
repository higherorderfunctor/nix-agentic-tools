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

echo "=== Updating package: $name ==="

wt=$(setup_worktree "$name")

if ! (
	cd "$wt"

	# shellcheck disable=SC2086
	nix run --inputs-from . nix-update -- --flake "$name" --commit --system "$system" $extra_flags

	# Build verification (runs derivation-level tests)
	# TODO: additional checks, smoke tests (future validation phase)
	nix build ".#$name" --no-link
); then
	report_skipped "$name" "nix-update or build failed"
	exit 0
fi

merge_to_branch "$wt" "$name"
report_updated "$name"
