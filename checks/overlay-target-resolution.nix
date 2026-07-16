# Overlay target-resolution regression gate.
#
# The update pipeline bumps a main-tracking package's rev by locating the
# overlay that pins its upstream repo. A prior implementation resolved
# that file with `grep -rl "<repo-basename>" | head -1`, which matched any
# overlay merely naming the basename (e.g. effect-mcp.nix's "Mirrors
# context7-mcp.nix." comment) and raced on `head -1`. The context7 update
# consequently rewrote effect-mcp.nix to a nonexistent rev → source 404 →
# red CI (and silently froze packages whose wrong file had no rev).
#
# This check runs the SAME resolver (dev/scripts/resolve-overlay-file.sh)
# the pipeline uses, against the SAME matrix (config/update-matrix.nix),
# and fails if any git-tracked package does not resolve to exactly one
# overlay carrying an inline `rev`. It makes the mis-resolution class a
# `nix flake check` failure at PR time instead of a pipeline surprise.
{
  lib,
  pkgs,
  ...
}: let
  matrix = import ../config/update-matrix.nix;
  # Only nix-update entries that carry a `git` URL go through rev-bump
  # resolution (main-tracking packages). Binary packages (--use-update-script)
  # have no `git` attr and manage their own sources.
  gitEntries = lib.filterAttrs (_: v: v ? git) matrix.nixUpdate;
  # "name<TAB>git-url" per line — name is only for diagnostics.
  table = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (name: v: "${name}\t${v.git}") gitEntries
  );
  tableFile = pkgs.writeText "update-matrix-git-urls.tsv" table;
in
  pkgs.runCommandLocal "overlay-target-resolution-check" {
    nativeBuildInputs = [pkgs.coreutils pkgs.findutils pkgs.gnugrep];
    src = ../.;
  } ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :

    cd "$src"
    # shellcheck source=dev/scripts/resolve-overlay-file.sh
    source dev/scripts/resolve-overlay-file.sh

    failures=""
    while IFS=$'\t' read -r name url; do
      [ -z "$name" ] && continue
      if ! file=$(resolve_overlay_file "$url" overlays 2>&1); then
        failures="$failures"$'\n'"  $name: $file"
        continue
      fi
      if ! grep -qE 'rev = "[a-f0-9]{40}' "$file"; then
        failures="$failures"$'\n'"  $name: resolved $file but it has no inline 40-hex rev"
        continue
      fi
      echo "  ok  $name -> $file"
    done < ${tableFile}

    if [ -n "$failures" ]; then
      echo "" >&2
      echo "ERROR: update-matrix packages that do not resolve to exactly one" >&2
      echo "overlay with an inline rev (see checks/overlay-target-resolution.nix):" >&2
      echo "$failures" >&2
      exit 1
    fi

    echo "All main-tracking packages resolve to a unique overlay with an inline rev."
    mkdir -p "$out"
    touch "$out/ok"
  ''
