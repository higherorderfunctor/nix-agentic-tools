#!/usr/bin/env bash
# dev/scripts/update-pkg.sh <package-name> [extra-nix-update-flags...]
# Update a single package in a worktree, verify build, merge back.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# shellcheck source-path=SCRIPTDIR
source "$(dirname "$0")/update-common.sh"

name="$1"
shift
extra_flags="$*"
system=$(nix eval --impure --raw --expr 'builtins.currentSystem')

log_header "Package: $name"

wt=$(setup_worktree "$name")
version_file="$wt/.update-version"

# Phase 1: Update (--no-commit: we commit after build validation)
log_info "Running nix-update..."
if ! (
	cd "$wt"

	# Capture nix-update output for version reporting
	# shellcheck disable=SC2086
	nix run --inputs-from . nix-update -- --flake "$name" --system "$system" $extra_flags 2>&1 | tee "$version_file"

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
	version_detail=$(parse_pkg_version "$version_file")
	report_held_back "$name" "nix-update or build failed" "$version_detail"
	exit 0
fi

# Extract version info
version_detail=$(parse_pkg_version "$version_file")

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
	report_held_back "$name" "cherry-pick conflict" "$version_detail"
	exit 0
elif [ "$rc" -eq 2 ]; then
	report_unchanged "$name"
	exit 0
fi
report_updated "$name" "$version_detail"
