#!/usr/bin/env bash
# dev/scripts/update-combo.sh
# Update any-buddy + claude-code together. Both must build as a working combo.
# If either fails, don't cherry-pick — worktree is disposable.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# shellcheck source=dev/scripts/update-common.sh
source "$(dirname "$0")/update-common.sh"

echo "=== Updating combo: any-buddy + claude-code ==="

system=$(nix eval --impure --raw --expr 'builtins.currentSystem')
wt=$(setup_worktree "any-buddy-claude-code")

if ! (
	cd "$wt"

	# Update any-buddy first
	nix run --inputs-from . nix-update -- --flake any-buddy --commit --system "$system"

	# Update claude-code
	nix run --inputs-from . nix-update -- --flake claude-code --commit --system "$system" --use-update-script

	# Build verification (runs derivation-level tests)
	# TODO: additional checks, smoke tests (future validation phase)
	nix build ".#any-buddy" ".#claude-code" --no-link
); then
	report_skipped "any-buddy+claude-code" "combo build failed — both held back"
	exit 0
fi

merge_to_branch "$wt" "any-buddy+claude-code"
report_updated "any-buddy+claude-code"
