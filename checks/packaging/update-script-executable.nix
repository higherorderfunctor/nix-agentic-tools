# Every `--use-update-script` target must hand nix-update an EXECUTABLE FILE.
#
# nix-update wraps `lib.toList (updateScript.command or updateScript)` in a
# `writeScript` and runs it, so the first element is argv[0]. A
# writeShellApplication derivation coerces to its output DIRECTORY (the script
# lives at $out/bin/<name>), so `passthru.updateScript = <writeShellApplication>`
# evaluates and builds cleanly and then fails every sweep with `Permission
# denied` (exit 126). kimchi-docs shipped that way in #1848 and was held back
# from its first scheduled sweep on. Nothing else runs an update script before
# the sweep does, so this realizes each argv[0] and tests it.
#
# The positive control rigs one real, present target's updateScript with a
# writeShellApplication (the exact kimchi-docs shape) and runs it through the
# SAME scriptTargets -> presentTargets -> table -> loop pipeline the real rows
# go through (see checks/packaging/update-targets-parity.nix for the same
# idiom), so it proves the loop can fail rather than exercising a hand-made
# stand-in off to the side.
{
  lib,
  pkgs,
  self,
  ...
}: {
  checks.update-script-executable = let
    packages = self.ciPackages.${pkgs.stdenv.hostPlatform.system};
    argv0 = package: let
      script = package.updateScript;
    in
      toString (builtins.head (lib.toList (script.command or script)));

    scriptTargets = lib.filterAttrs (_: target: builtins.elem "--use-update-script" target.flags) self.updateTargets;
    # A target absent from this system's package set is not run here; list it
    # instead of dropping it silently.
    absentTargets = builtins.filter (name: !(builtins.hasAttr name packages)) (builtins.attrNames scriptTargets);
    presentTargets = lib.filterAttrs (name: _: builtins.hasAttr name packages) scriptTargets;
    missingScripts = builtins.filter (name: !(packages.${name} ? updateScript)) (builtins.attrNames presentTargets);

    # Builds the "name<TAB>argv0" table the check's shell loop consumes, from
    # `packages` with `overrides` spliced onto individual entries before the
    # SAME presentTargets filter is applied. Used unchanged for the real rows
    # (no overrides) and for the positive control below (one row's
    # updateScript replaced), so the control is fed through the exact
    # pipeline that gates real rows rather than a hand-made stand-in.
    mkTable = overrides: let
      merged = packages // lib.mapAttrs (name: extra: packages.${name} // extra) overrides;
    in
      lib.concatStrings (
        lib.mapAttrsToList (name: _: "${name}\t${argv0 merged.${name}}\n")
        (lib.filterAttrs (name: _: merged.${name} ? updateScript) presentTargets)
      );
    table = mkTable {};

    # Positive control: rig one real, present target with the exact shape
    # that held kimchi-docs back (a writeShellApplication coercing to its
    # output DIRECTORY rather than a script FILE). run_check below must
    # reject only that row, with the same remedy message a real regression
    # would get.
    controlName = builtins.head (builtins.attrNames presentTargets);
    brokenTable = mkTable {
      ${controlName}.updateScript = pkgs.writeShellApplication {
        name = "update-script-executable-positive-control";
        text = "true";
      };
    };
  in
    pkgs.runCommandLocal "update-script-executable-check" {
      absent = lib.concatStringsSep " " absentTargets;
      missing = lib.concatStringsSep " " missingScripts;
      inherit controlName;
      passAsFile = ["table" "brokenTable"];
      inherit table brokenTable;
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      runnable() {
        [ -f "$1" ] && [ -x "$1" ]
      }

      # The gating logic itself: for every "name<TAB>argv0" row, argv0 must be
      # an executable file. Prints an ok/fail line per row and returns
      # non-zero, with the remedy message on stderr, if any row fails. Shared
      # by the real table and the positive control below so the control
      # exercises exactly what gates real rows.
      run_check() {
        local table_file="$1" failures=""
        while IFS=$'\t' read -r name script; do
          if runnable "$script"; then
            echo "  ok  $name -> $script"
          else
            failures="$failures"$'\n'"  $name: $script is not an executable file ($(stat -c %F "$script" 2>&1 || echo missing))"
          fi
        done < "$table_file"
        if [ -n "$failures" ]; then
          echo "" >&2
          echo "ERROR: nix-update runs the first element of updateScript as a program." >&2
          echo "Pass lib.getExe <script> for a writeShellApplication, not the derivation:" >&2
          echo "$failures" >&2
          return 1
        fi
      }

      # Positive control first: run_check must reject $controlName once its
      # updateScript is rigged, through the same table+loop code that gates
      # the real rows below. The expected failure is captured here, not
      # allowed to abort the build.
      if controlOutput=$(run_check "$brokenTablePath" 2>&1); then
        echo "ERROR: positive control ($controlName rigged with a" >&2
        echo "writeShellApplication updateScript) passed run_check; it cannot" >&2
        echo "tell a broken row from a working one:" >&2
        echo "$controlOutput" >&2
        exit 1
      fi
      if ! grep -q "is not an executable file" <<<"$controlOutput"; then
        echo "ERROR: positive control failed for the wrong reason (expected" >&2
        echo "the executable-file remedy message):" >&2
        echo "$controlOutput" >&2
        exit 1
      fi

      if [ ! -s "$tablePath" ]; then
        echo "ERROR: no --use-update-script target resolved to an update script" >&2
        exit 1
      fi

      if [ -n "$missing" ]; then
        echo "ERROR: --use-update-script targets whose package has no updateScript: $missing" >&2
        exit 1
      fi
      if [ -n "$absent" ]; then
        echo "not in this system's package set, not checked: $absent"
      fi

      if ! run_check "$tablePath"; then
        exit 1
      fi

      touch "$out"
    '';
}
