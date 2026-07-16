#!/usr/bin/env bash
# dev/scripts/resolve-overlay-file.sh — deterministic overlay-file
# resolution for the update pipeline. Sourced by update-common.sh (and
# thus update-pkg.sh) and by checks/overlay-target-resolution.nix.
#
# Pure library: defines one function, no top-level side effects, safe to
# source anywhere (script, test harness, nix sandbox).
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :

# resolve_overlay_file <git-url> <overlays-root>
#
# Print, on stdout, the single overlay .nix file that pins the upstream
# repo named by <git-url>. Return 0 on exactly one match; return 1 with a
# diagnostic on stderr for zero or multiple matches.
#
# WHY THIS EXISTS: the previous resolution was
#     repo_name=$(basename-of-url)                    # e.g. "context7"
#     target_file=$(grep -rl "$repo_name" overlays | head -1)
# which matched ANY file merely mentioning the bare repo basename —
# including unrelated overlays naming it in a comment (effect-mcp.nix
# carries "Mirrors context7-mcp.nix.") — and `head -1` over grep -r's
# streamed, unordered output is a race that resolves to different files
# on different runs/hosts. That silently rewrote the wrong overlay:
# context7's HEAD rev was written into effect-mcp's fetch block, pinning
# a nonexistent tim-smart/effect-mcp commit → source 404 → red CI.
#
# The upstream repo's *identity* already lives unambiguously in the fetch
# block. Match on that, in either supported form:
#   - fetchFromGitHub { owner = "<owner>"; repo = "<repo>"; ... }
#   - fetchgit        { url = "...github.com/<owner>/<repo>.git"; ... }
# and require exactly one match, so an ambiguous/missing mapping fails
# loudly (HELD BACK) instead of silently corrupting a sibling overlay.
resolve_overlay_file() {
  local git_url="$1" root="$2"

  # Parse github.com/<owner>/<repo> from the matrix git URL (always the
  # https form: https://github.com/<owner>/<repo>.git).
  local path owner repo
  path=${git_url#https://github.com/}
  path=${path#http://github.com/}
  path=${path%.git}
  path=${path%/}
  owner=${path%%/*}
  repo=${path#*/}
  if [ -z "$owner" ] || [ -z "$repo" ] || [ "$owner" = "$path" ] || [[ $repo == */* ]]; then
    echo "resolve_overlay_file: cannot parse owner/repo from '$git_url'" >&2
    return 1
  fi

  # Overlays are treefmt/alejandra-formatted, so attribute spacing is
  # canonical (`owner = "X";`). Match fixed strings to avoid regex
  # metacharacter surprises in owner/repo (dots, etc.).
  local f
  local -a matches=()
  while IFS= read -r f; do
    if { grep -qF "owner = \"${owner}\"" "$f" &&
      grep -qF "repo = \"${repo}\"" "$f"; } ||
      grep -qF "github.com/${owner}/${repo}" "$f"; then
      matches+=("$f")
    fi
  done < <(find "$root" -type f -name '*.nix' | sort)

  if [ "${#matches[@]}" -eq 1 ]; then
    printf '%s\n' "${matches[0]}"
    return 0
  fi

  echo "resolve_overlay_file: expected exactly 1 overlay pinning ${owner}/${repo}, found ${#matches[@]}: ${matches[*]:-<none>}" >&2
  return 1
}
