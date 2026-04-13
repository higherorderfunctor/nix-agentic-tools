#!/usr/bin/env bash
# dev/scripts/update-pkg.sh <package-name> <nix-update-flags> [git-url]
# Update a single package in a worktree, verify build, merge back.
# If git-url is provided, bumps rev to latest default branch commit first.
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# shellcheck source-path=SCRIPTDIR
source "$(dirname "$0")/update-common.sh"

name="$1"
shift

# Parse args: flags are everything except a trailing .git URL
git_url=""
args=("$@")
if [ ${#args[@]} -gt 0 ] && [[ ${args[-1]} == *.git ]]; then
  git_url="${args[-1]}"
  unset 'args[-1]'
fi
extra_flags="${args[*]:-}"
system=$(nix eval --impure --raw --expr 'builtins.currentSystem')

log_header "Package: $name"

wt=$(setup_worktree "$name")
version_file="$wt/.update-version"
base_head=$(git rev-parse "$BRANCH")

# Phase 0: Bump rev to latest default branch commit (main-tracking packages)
if [ -n "$git_url" ]; then
  log_info "Fetching latest rev from $git_url..."
  new_rev=$(git ls-remote "$git_url" HEAD | cut -f1)
  if [ -n "$new_rev" ]; then
    repo_name=$(echo "$git_url" | sed 's|\.git$||' | grep -oP '[^/]+$')
    target_file=$(grep -rl "$repo_name" "$wt/overlays" --include='*.nix' | head -1)
    if [ -n "$target_file" ]; then
      old_rev=$(grep -oP 'rev = "\K[a-f0-9]{40}' "$target_file" | head -1 || true)
      if [ -n "$old_rev" ] && [ "$old_rev" != "$new_rev" ]; then
        sed -i "s|$old_rev|$new_rev|g" "$target_file"
        # Prefetch new source hash
        old_hash=$(grep -oP 'hash = "\Ksha256-[^"]+' "$target_file" | head -1 || true)
        if [ -n "$old_hash" ]; then
          flake_ref="github:$(echo "$git_url" | sed 's|\.git$||' | grep -oP 'github\.com/\K.*')/$new_rev"
          new_hash=$(nix flake prefetch --json "$flake_ref" 2>/dev/null | jq -r '.hash // empty')
          if [ -n "$new_hash" ]; then
            sed -i "s|$old_hash|$new_hash|" "$target_file"
            log_info "Hash updated in $(basename "$target_file")"
          fi
        fi
        log_info "Rev: ${old_rev:0:7} -> ${new_rev:0:7} in $(basename "$target_file")"

        # Commit rev + src hash so nix-update has a clean tree to evaluate
        git -C "$wt" add -A
        git -C "$wt" commit -m "chore(overlays): update $name"
      fi
    fi
  fi
fi

# Phase 1: Update dep hashes via nix-update (needs clean committed state)
log_info "Running nix-update..."
if ! (
  cd "$wt"

  # shellcheck disable=SC2086
  nix run --inputs-from . nix-update -- --flake "$name" --system "$system" $extra_flags 2>&1 | tee "$version_file"

  # Amend dep hash changes into the existing commit if any
  if ! git -C "$wt" diff --quiet || ! git -C "$wt" diff --staged --quiet; then
    git -C "$wt" add -A
    git -C "$wt" commit --amend --no-edit
  fi

  # Nothing changed from base
  if [ "$(git -C "$wt" rev-parse HEAD)" = "$base_head" ]; then
    exit 0
  fi

  # Prefetch source for cachix (CI only — enables eval on PR runners)
  prefetch_sources "$name"

  # Phase 2: Build verification (skipped in CI mode)
  run_build nix build ".#$name" --no-link --log-format bar-with-logs
); then
  version_detail=$(parse_pkg_version "$version_file")
  report_held_back "$name" "nix-update or build failed" "$version_detail"
  exit 0
fi

# Extract version info
version_detail=$(parse_pkg_version "$version_file")

# Check if the worktree actually made commits
wt_head=$(git -C "$wt" rev-parse HEAD)
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
