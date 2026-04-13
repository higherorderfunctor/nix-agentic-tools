#!/usr/bin/env bash
# dev/scripts/update-combo.sh
# Update any-buddy + claude-code together. Both must build as a working combo.
# If either fails, don't advance — worktree branch is disposable.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# shellcheck source-path=SCRIPTDIR
source "$(dirname "$0")/update-common.sh"

log_header "Combo: any-buddy + claude-code"

system=$(nix eval --impure --raw --expr 'builtins.currentSystem')
wt=$(setup_worktree "any-buddy-claude-code")
version_file="$wt/.update-version"
base_head=$(git rev-parse "$BRANCH")

# Phase 0: Bump any-buddy rev (main-tracking)
ANY_BUDDY_GIT="https://github.com/cpaczek/any-buddy.git"
log_info "Fetching latest any-buddy rev..."
new_rev=$(git ls-remote "$ANY_BUDDY_GIT" HEAD | cut -f1)
if [ -n "$new_rev" ]; then
  target_file="$wt/overlays/any-buddy.nix"
  old_rev=$(grep -oP 'rev = "\K[a-f0-9]{40}' "$target_file" || true)
  if [ -n "$old_rev" ] && [ "$old_rev" != "$new_rev" ]; then
    sed -i "s|$old_rev|$new_rev|g" "$target_file"
    old_hash=$(grep -oP 'hash = "\Ksha256-[^"]+' "$target_file" | head -1 || true)
    if [ -n "$old_hash" ]; then
      new_hash=$(nix flake prefetch --json "github:cpaczek/any-buddy/$new_rev" 2>/dev/null | jq -r '.hash // empty')
      if [ -n "$new_hash" ]; then
        sed -i "s|$old_hash|$new_hash|" "$target_file"
        log_info "Hash updated in any-buddy.nix"
      fi
    fi
    log_info "any-buddy rev: ${old_rev:0:7} -> ${new_rev:0:7}"

    # Commit rev + src hash so nix-update has a clean tree to evaluate
    git -C "$wt" add -A
    git -C "$wt" commit -m "chore(overlays): update any-buddy + claude-code"
  fi
fi

# Phase 1: Update dep hashes via nix-update (needs clean committed state)
log_info "Running nix-update for any-buddy + claude-code..."
if ! (
  cd "$wt"

  {
    nix run --inputs-from . nix-update -- --flake any-buddy --system "$system" --version skip
    nix run --inputs-from . nix-update -- --flake claude-code --system "$system" --use-update-script
  } 2>&1 | tee "$version_file"

  # Amend dep hash changes into the existing commit if any
  if ! git -C "$wt" diff --quiet || ! git -C "$wt" diff --staged --quiet; then
    git -C "$wt" add -A
    git -C "$wt" commit --amend --no-edit
  fi

  # Nothing changed from base
  if [ "$(git -C "$wt" rev-parse HEAD)" = "$base_head" ]; then
    exit 0
  fi

  # Phase 2: Build verification (skipped in CI mode)
  run_build nix build ".#any-buddy" ".#claude-code" --no-link --log-format bar-with-logs
); then
  version_detail=$(parse_pkg_version "$version_file")
  report_held_back "any-buddy+claude-code" "combo update or build failed" "$version_detail"
  exit 0
fi

# Extract version info
version_detail=$(parse_pkg_version "$version_file")

# Check if the worktree actually made commits
wt_head=$(git -C "$wt" rev-parse HEAD)
if [ "$wt_head" = "$base_head" ]; then
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
