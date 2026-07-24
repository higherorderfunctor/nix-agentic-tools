# Update-target resolution + parity gate (config.update.targets ↔ overlays).
#
# config/update-matrix.nix was dissolved into config.update.targets, so this is
# now the SOLE update-target gate — there is no coexisting matrix to reconcile.
# config.update.targets (lib/update.nix + config/update-targets.nix + the
# co-located overlays/mcp-servers/effect-mcp.update.nix, exposed as the
# `.#updateTargets` flake output) is the single source of truth the pipeline
# reads.
#
# For EVERY main-tracking target (one carrying a `git` URL — binary
# `--use-update-script` packages manage their own sources and never hit
# resolve_overlay_file), this asserts three things, folding in the old
# checks/overlay-target-resolution.nix regression gate:
#   (a) `file` is non-null (main-tracking packages MUST declare an overlay).
#   (b) `file` == resolve_overlay_file(<git>, overlays) — byte-identical to the
#       exact string update-pkg.sh consumes, so the declared path can never
#       drift from what the deterministic resolver would otherwise pick.
#   (c) that resolved file carries an inline 40-hex `rev = "…"`, so the rev-bump
#       actually has something to sed (a mis-resolution to a rev-less file would
#       silently freeze the package).
#
# Runs the SAME resolver (dev/scripts/resolve-overlay-file.sh) the pipeline
# uses, against the SAME overlays tree.
{
  lib,
  pkgs,
  self,
}: let
  inherit (self) updateTargets;
  # Only entries that carry a `git` URL go through rev-bump resolution
  # (main-tracking packages); binary packages have `git = null`.
  gitEntries = lib.filterAttrs (_: v: v.git != null) updateTargets;
  # "name<TAB>git-url<TAB>declared-file" per line — name is for diagnostics. A
  # null `file` is emitted as the empty string so assertion (a) can flag it.
  table = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      name: v: "${name}\t${v.git}\t${
        if v.file == null
        then ""
        else v.file
      }"
    )
    gitEntries
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

    # An empty set means every main-tracking target lost its `git` URL — the
    # dissolved registry is expected to carry ~18 of them. Fail loudly rather
    # than pass by absence.
    if [ ! -s ${tableFile} ]; then
      echo "ERROR: no config.update.targets entry carries a git URL. The" >&2
      echo "dissolved registry expects ~18 main-tracking targets — did the" >&2
      echo "update-target wiring get dropped?" >&2
      exit 1
    fi

    failures=""
    # `|| [ -n "$name" ]` processes the final line even though the TSV has no
    # trailing newline (concatStringsSep produces none): otherwise bash `read`
    # returns non-zero at EOF and the last alphabetical entry is silently
    # skipped — never validated.
    while IFS=$'\t' read -r name url declared || [ -n "$name" ]; do
      [ -z "$name" ] && continue
      # (a) main-tracking targets MUST declare an overlay file.
      if [ -z "$declared" ]; then
        failures="$failures"$'\n'"  $name: has a git URL but config.update.targets.$name.file is null"
        continue
      fi
      # (b) declared file must be byte-identical to the resolver output.
      if ! resolved=$(resolve_overlay_file "$url" overlays 2>&1); then
        failures="$failures"$'\n'"  $name: resolver failed: $resolved"
        continue
      fi
      if [ "$resolved" != "$declared" ]; then
        failures="$failures"$'\n'"  $name: config.update.targets.$name.file = '$declared' but resolve_overlay_file printed '$resolved'"
        continue
      fi
      # (c) the resolved file must carry an inline 40-hex rev to sed-bump.
      if ! grep -qE 'rev = "[a-f0-9]{40}' "$resolved"; then
        failures="$failures"$'\n'"  $name: resolved $resolved but it has no inline 40-hex rev"
        continue
      fi
      echo "  ok  $name -> $declared (byte-identical to resolver, inline rev present)"
    done < ${tableFile}

    if [ -n "$failures" ]; then
      echo "" >&2
      echo "ERROR: config.update.targets.<name>.file diverges from the" >&2
      echo "deterministic resolver the update pipeline uses, or the resolved" >&2
      echo "overlay lacks an inline rev (see checks/update-targets-parity.nix):" >&2
      echo "$failures" >&2
      exit 1
    fi

    echo "All main-tracking update targets are byte-identical to resolve_overlay_file output and carry an inline rev."
    mkdir -p "$out"
    touch "$out/ok"
  ''
