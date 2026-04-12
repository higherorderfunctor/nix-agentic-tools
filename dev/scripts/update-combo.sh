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
version_file="$wt/.update-version"

# Phase 0: Bump any-buddy rev (main-tracking)
ANY_BUDDY_GIT="https://github.com/cpaczek/any-buddy.git"
log_info "Fetching latest any-buddy rev..."
new_rev=$(git ls-remote "$ANY_BUDDY_GIT" HEAD | cut -f1)
if [ -n "$new_rev" ]; then
  old_rev=$(grep -oP 'rev = "\K[a-f0-9]{40}' "$wt/overlays/any-buddy.nix" || true)
  if [ -n "$old_rev" ] && [ "$old_rev" != "$new_rev" ]; then
    sed -i "s|$old_rev|$new_rev|g" "$wt/overlays/any-buddy.nix"
    log_info "any-buddy rev: ${old_rev:0:7} -> ${new_rev:0:7}"
  fi
fi

# Phase 1: Update hashes for both
log_info "Running nix-update for any-buddy + claude-code..."
if ! (
  cd "$wt"

  # Capture nix-update output for version reporting
  {
    nix run --inputs-from . nix-update -- --flake any-buddy --system "$system" --version skip
    nix run --inputs-from . nix-update -- --flake claude-code --system "$system" --use-update-script
  } 2>&1 | tee "$version_file"

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
  version_detail=$(parse_pkg_version "$version_file")
  report_held_back "any-buddy+claude-code" "combo update or build failed" "$version_detail"
  exit 0
fi

# Extract version info
version_detail=$(parse_pkg_version "$version_file")

# Check if the worktree actually made commits
wt_head=$(git -C "$wt" rev-parse HEAD)
base=$(cat "$wt/.update-base")
if [ "$wt_head" = "$base" ]; then
  report_unchanged "any-buddy+claude-code"
  exit 0
fi

merge_to_branch "$wt" "any-buddy+claude-code" || rc=$?
rc=${rc:-0}
if [ "$rc" -eq 1 ]; then
  report_held_back "any-buddy+claude-code" "cherry-pick conflict" "$version_detail"
  exit 0
elif [ "$rc" -eq 2 ]; then
  report_unchanged "any-buddy+claude-code"
  exit 0
fi
report_updated "any-buddy+claude-code" "$version_detail"
