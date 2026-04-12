#!/usr/bin/env bash
# dev/scripts/update-input.sh <input-name>
# Update a single flake input in a worktree, verify build, merge back.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# shellcheck source=dev/scripts/update-common.sh
source "$(dirname "$0")/update-common.sh"

name="$1"
echo "=== Updating input: $name ==="

wt=$(setup_worktree "$name")

# Update the input in the worktree
if ! (
	cd "$wt"
	nix flake update "$name"

	# Regenerate devenv.yaml from updated flake.lock
	nix eval --raw --impure --expr 'import ./config/generate-devenv-yaml.nix {}' >devenv.yaml

	# Sync devenv.lock
	devenv update

	# Commit atomically in worktree
	git add flake.lock devenv.yaml devenv.lock
	if git diff --staged --quiet; then
		echo "$name: already up to date"
		exit 0
	fi
	git commit -m "chore: update input $name"

	# Build verification (runs derivation-level tests)
	# TODO: additional checks, smoke tests (future validation phase)
	nix run --inputs-from . nix-fast-build -- --skip-cached --no-nom --no-link --flake ".#packages.$(nix eval --impure --raw --expr 'builtins.currentSystem')"
); then
	report_skipped "$name" "build failed after input update"
	exit 0
fi

merge_to_branch "$wt" "$name"
report_updated "$name"
