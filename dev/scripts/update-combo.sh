#!/usr/bin/env bash
# dev/scripts/update-combo.sh
# Update any-buddy + claude-code together. Both must build as a working combo.
# If either fails, don't cherry-pick — worktree is disposable.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# shellcheck source-path=SCRIPTDIR
source "$(dirname "$0")/update-common.sh"

log_header "Combo: any-buddy + claude-code"

system=$(nix eval --impure --raw --expr 'builtins.currentSystem')
wt=$(setup_worktree "any-buddy-claude-code")

# Phase 1: Update both (--no-commit: we commit after build validation)
log_info "Running nix-update for any-buddy..."
if ! (
	cd "$wt"

	# Update any-buddy
	nix run --inputs-from . nix-update -- --flake any-buddy --system "$system"

	# Update claude-code
	log_info "Running nix-update for claude-code..."
	nix run --inputs-from . nix-update -- --flake claude-code --system "$system" --use-update-script

	# Check if either made changes
	if git -C "$wt" diff --quiet && git -C "$wt" diff --staged --quiet; then
		exit 0
	fi

	# Phase 2: Both must build (runs derivation-level tests)
	# TODO: additional checks, smoke tests (future validation phase)
	nix build ".#any-buddy" ".#claude-code" --no-link --log-format bar-with-logs

	# Phase 3: Commit only after build passes
	git -C "$wt" add -A
	git -C "$wt" commit -m "chore(overlays): update any-buddy + claude-code"
); then
	report_held_back "any-buddy+claude-code" "combo update or build failed"
	exit 0
fi

# Check if the worktree actually made commits
wt_head=$(git -C "$wt" rev-parse HEAD)
base=$(cat "$wt/.update-base")
if [ "$wt_head" = "$base" ]; then
	report_unchanged "any-buddy+claude-code"
	exit 0
fi

merge_to_branch "$wt" "any-buddy+claude-code"
report_updated "any-buddy+claude-code"
