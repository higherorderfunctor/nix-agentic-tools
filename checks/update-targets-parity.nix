# Update-target parity gate (config.update.targets ↔ resolve_overlay_file).
#
# During the Track-A "config.update.targets merge-up" beachhead,
# config.update.targets (lib/update.nix + per-package `<pkg>.update.nix`
# contributions, exposed as the `.#updateTargets` flake output) COEXISTS with
# the live config/update-matrix.nix fallback. Only effect-mcp is migrated so
# far; the matrix stays authoritative for every other package.
#
# This check makes "the declared file is byte-identical to what the pipeline
# would otherwise resolve" a PERMANENT CI gate. For every package present in
# BOTH updateMatrix.nixUpdate (carrying a `git` URL — the main-tracking,
# rev-bump-resolved population) AND updateTargets, it asserts
#   updateTargets.<name>.file == resolve_overlay_file(<git>, overlays)
# — the exact string update-pkg.sh consumes. If the two ever diverge, the
# merged-up target would bump a different file than the matrix fallback,
# silently corrupting the coexistence guarantee. For the beachhead the
# intersection is exactly effect-mcp.
#
# Runs the SAME resolver (dev/scripts/resolve-overlay-file.sh) the pipeline
# uses, against the SAME overlays tree — mirroring
# checks/overlay-target-resolution.nix.
{
  lib,
  pkgs,
  self,
}: let
  matrix = self.updateMatrix;
  inherit (self) updateTargets;
  # Only nix-update entries that carry a `git` URL go through rev-bump
  # resolution (main-tracking packages); binary packages manage their own
  # sources and never hit resolve_overlay_file.
  gitEntries = lib.filterAttrs (_: v: v ? git) matrix.nixUpdate;
  # Packages in BOTH populations: a matrix git-entry AND a declared target.
  bothNames = lib.filter (name: updateTargets ? ${name}) (lib.attrNames gitEntries);
  # "name<TAB>git-url<TAB>declared-file" per line — name is for diagnostics.
  table = lib.concatStringsSep "\n" (
    map (name: "${name}\t${gitEntries.${name}.git}\t${updateTargets.${name}.file}") bothNames
  );
  tableFile = pkgs.writeText "update-targets-parity.tsv" table;
in
  pkgs.runCommandLocal "update-targets-parity-check" {
    nativeBuildInputs = [pkgs.coreutils pkgs.findutils pkgs.gnugrep];
    src = ../.;
  } ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :

    cd "$src"
    # shellcheck source=dev/scripts/resolve-overlay-file.sh
    source dev/scripts/resolve-overlay-file.sh

    # An empty intersection means the merge-up wiring was dropped (the
    # beachhead expects at least effect-mcp). Fail loudly rather than pass by
    # absence.
    if [ ! -s ${tableFile} ]; then
      echo "ERROR: no package is present in BOTH updateMatrix.nixUpdate (with a" >&2
      echo "git URL) and config.update.targets. The beachhead expects at least" >&2
      echo "effect-mcp — did the merge-up wiring get dropped?" >&2
      exit 1
    fi

    failures=""
    # `|| [ -n "$name" ]` processes the final line even though the TSV has no
    # trailing newline (concatStringsSep produces none) — see the same guard in
    # checks/overlay-target-resolution.nix.
    while IFS=$'\t' read -r name url declared || [ -n "$name" ]; do
      [ -z "$name" ] && continue
      if ! resolved=$(resolve_overlay_file "$url" overlays 2>&1); then
        failures="$failures"$'\n'"  $name: resolver failed: $resolved"
        continue
      fi
      if [ "$resolved" != "$declared" ]; then
        failures="$failures"$'\n'"  $name: config.update.targets.$name.file = '$declared' but resolve_overlay_file printed '$resolved'"
        continue
      fi
      echo "  ok  $name -> $declared (byte-identical to resolver output)"
    done < ${tableFile}

    if [ -n "$failures" ]; then
      echo "" >&2
      echo "ERROR: config.update.targets.<name>.file diverges from the" >&2
      echo "deterministic resolver the update pipeline uses (see" >&2
      echo "checks/update-targets-parity.nix):" >&2
      echo "$failures" >&2
      exit 1
    fi

    echo "All merged-up update targets are byte-identical to resolve_overlay_file output."
    mkdir -p "$out"
    touch "$out/ok"
  ''
