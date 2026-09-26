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
{
  lib,
  pkgs,
  self,
  ...
}: {
  checks.update-script-executable = let
    packages = self.packages.${pkgs.stdenv.hostPlatform.system};
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
    table = lib.concatStrings (
      lib.mapAttrsToList (name: _: "${name}\t${argv0 packages.${name}}\n")
      (lib.filterAttrs (name: _: packages.${name} ? updateScript) presentTargets)
    );

    # Positive control: the exact shape that held kimchi-docs back. The test
    # below must reject it, or it proves nothing about the real rows.
    positiveControl = argv0 {
      updateScript = pkgs.writeShellApplication {
        name = "update-script-executable-positive-control";
        text = "true";
      };
    };
  in
    pkgs.runCommandLocal "update-script-executable-check" {
      absent = lib.concatStringsSep " " absentTargets;
      missing = lib.concatStringsSep " " missingScripts;
      passAsFile = ["table"];
      inherit positiveControl table;
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      runnable() {
        [ -f "$1" ] && [ -x "$1" ]
      }

      if runnable "$positiveControl"; then
        echo "ERROR: positive control $positiveControl (a writeShellApplication output) passed the executable test" >&2
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

      failures=""
      while IFS=$'\t' read -r name script; do
        if runnable "$script"; then
          echo "  ok  $name -> $script"
        else
          failures="$failures"$'\n'"  $name: $script is not an executable file ($(stat -c %F "$script"))"
        fi
      done < "$tablePath"

      if [ -n "$failures" ]; then
        echo "" >&2
        echo "ERROR: nix-update runs the first element of updateScript as a program." >&2
        echo "Pass lib.getExe <script> for a writeShellApplication, not the derivation:" >&2
        echo "$failures" >&2
        exit 1
      fi

      touch "$out"
    '';
}
