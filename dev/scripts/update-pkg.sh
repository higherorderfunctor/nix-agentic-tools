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
        # Prefetch new source hash + storePath (used below for upstream
        # version re-derivation; one prefetch, two uses)
        old_hash=$(grep -oP 'hash = "\Ksha256-[^"]+' "$target_file" | head -1 || true)
        storePath=""
        if [ -n "$old_hash" ]; then
          flake_ref="github:$(echo "$git_url" | sed 's|\.git$||' | grep -oP 'github\.com/\K.*')/$new_rev"
          prefetch_json=$(nix flake prefetch --json "$flake_ref" 2>/dev/null || true)
          if [ -n "$prefetch_json" ]; then
            new_hash=$(echo "$prefetch_json" | jq -r '.hash // empty')
            storePath=$(echo "$prefetch_json" | jq -r '.storePath // empty')
            if [ -n "$new_hash" ]; then
              sed -i "s|$old_hash|$new_hash|" "$target_file"
              log_info "Hash updated in $(basename "$target_file")"
            fi
          fi
        fi
        log_info "Rev: ${old_rev:0:7} -> ${new_rev:0:7} in $(basename "$target_file")"

        # Re-derive upstream version literals from the fresh src.
        # The overlay carries a magic comment on the line preceding
        # each `upstream = "..."` literal, naming which vu.read* helper
        # to invoke and the manifest path relative to src:
        #
        #   # upstream: readPackageJsonVersion @ packages/foo/package.json
        #   upstream = "1.2.3";
        #
        # This eliminates eval-time IFD — overlays no longer call
        # vu.read* at eval time (which forced realization of the
        # platform-tagged src drv and broke cross-platform eval on
        # PR CI). See .claude/rules/overlays.md § IFD Patterns.
        #
        # One file can carry multiple markers (e.g.,
        # modelcontextprotocol/default.nix has 7 sub-packages, and
        # two of them happen to share the same manifest path). The
        # Python filter indexes by LINE NUMBER so each marker drives
        # its own replacement.
        if [ -n "$storePath" ] && grep -q '# upstream: ' "$target_file"; then
          # Emit "line-number|kind|manifest" for every marker in the
          # file, then the Python filter below does all replacements
          # in one pass against the target file.
          markers=$(awk '
            match($0, /# upstream: ([A-Za-z]+) @ (.+)$/, arr) {
              if (arr[1] != "" && arr[2] != "") print NR "|" arr[1] "|" arr[2];
            }
          ' "$target_file")
          if [ -n "$markers" ]; then
            # For each marker, resolve the new upstream value via nix
            # eval of the corresponding vu.read* helper against the
            # fresh src, then feed a JSON array of
            # {lineno, new_value} pairs to Python to rewrite the file.
            resolved="[]"
            while IFS='|' read -r lineno kind manifest_rel; do
              [ -z "$lineno" ] && continue
              new_upstream=$(nix eval --impure --raw --expr "
                let vu = import (toString $PWD/overlays/lib.nix);
                in vu.$kind ($storePath + \"/$manifest_rel\")
              " 2>/dev/null || true)
              if [ -z "$new_upstream" ]; then
                log_info "Could not derive upstream from $manifest_rel via $kind"
                continue
              fi
              resolved=$(echo "$resolved" | jq --arg n "$lineno" --arg v "$new_upstream" \
                '. + [{lineno: ($n | tonumber), value: $v}]')
              log_info "Upstream (L$lineno): $kind @ $manifest_rel -> $new_upstream"
            done <<<"$markers"
            if [ "$resolved" != "[]" ]; then
              python3 - "$target_file" "$resolved" <<'PY'
import json, re, sys
path, spec = sys.argv[1], sys.argv[2]
entries = json.loads(spec)
with open(path) as f:
    lines = f.read().split("\n")
pat = re.compile(r'^(\s*(?:upstream|upstreamVersion|version)\s*=\s*(?:mkPyVersion\s+)?)"[^"]*"(.*)$')
for e in entries:
    marker_idx = e["lineno"] - 1  # awk is 1-based, python 0-based
    # Replace the FIRST upstream literal that follows this marker
    # (usually the very next line; 5-line window absorbs rare
    # intervening comments/whitespace).
    for j in range(marker_idx + 1, min(marker_idx + 6, len(lines))):
        m = pat.match(lines[j])
        if m:
            lines[j] = f'{m.group(1)}"{e["value"]}"{m.group(2)}'
            break
with open(path, "w") as f:
    f.write("\n".join(lines))
PY
            fi
          fi
        fi

        # Commit rev + src hash + upstream version so nix-update has a
        # clean tree to evaluate
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

  # Prime the src derivation file in the store. `nix flake prefetch`
  # (Phase 0) populates the source output but does NOT create a .drv
  # for the fetchFromGitHub derivation — .drv files are machine-local
  # and not produced by the flake-prefetch builtin. nix-update's
  # internal nix-instantiate then fails at `readFile "${src}/..."`
  # with "path '...source.drv' is not valid" because readFile's
  # context-realization needs the drv registered. A single
  # `nix eval` on drvPath instantiates the derivation file without
  # building the output, which is enough to unblock nix-update.
  nix eval --raw ".#$name.src.drvPath" >/dev/null 2>&1 || true

  # shellcheck disable=SC2086
  nix run --inputs-from . nix-update -- --flake "$name" --system "$system" $extra_flags 2>&1 | tee "$version_file"
  # pipefail propagates nix-update failures through tee
  nix_update_status=${PIPESTATUS[0]}
  if [ "$nix_update_status" -ne 0 ]; then
    log_failure "nix-update exited $nix_update_status"
    exit 1
  fi

  # Commit dep hash changes (amend if update commit exists, new commit otherwise)
  if ! git -C "$wt" diff --quiet || ! git -C "$wt" diff --staged --quiet; then
    git -C "$wt" add -A
    if [ "$(git -C "$wt" rev-parse HEAD)" != "$base_head" ]; then
      git -C "$wt" commit --amend --no-edit
    else
      git -C "$wt" commit -m "chore(overlays): update $name"
    fi
  fi

  # Nothing changed from base
  if [ "$(git -C "$wt" rev-parse HEAD)" = "$base_head" ]; then
    exit 0
  fi

  # Phase 2: Build verification (skipped in CI mode)
  run_build nix build ".#$name" --no-link --log-format bar-with-logs
); then
  version_detail=$(parse_pkg_version "$version_file")
  # Roll back the Phase 0 rev+src commit so a held-back package does
  # NOT leave a branch ahead of base. The PR-creation step in
  # .github/workflows/update.yml filters on `wt_head == base_head`, so
  # resetting here is what makes held-back packages skip their PR.
  # Successful targets keep their commit and open their PR as before.
  git -C "$wt" reset --hard "$base_head"
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
