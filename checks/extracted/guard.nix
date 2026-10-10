# The facts contract's guard: owners supply data and extractors only. Every
# tracked code file outside lib/extracted/ and checks/extracted/ is scanned
# for the three things only those directories may do: read a per-system raw
# path, reach into `bySystem`, or state a combine rule as data.
#
# Code means .nix .py .mjs .js .sh .bash. Markdown, including every
# generated instruction projection, describes the contract and is not
# scanned; decisions.json is where combine rules belong.
#
# Only git-tracked files reach the flake source, so the scan is of tracked
# files. AN EMPTY FILE SET IS A HARD FAILURE, for the reason given in
# checks/markdown/markdown-scan.nix: a scan of nothing exits 0.
#
# Controls run first, so a guard that cannot fail does not pass the tree.
{
  lib,
  pkgs,
  ...
}: let
  systems = lib.concatMapStringsSep "|" lib.escapeRegex (import ../../config/systems.nix);
  vocabulary = "equal|and|or|max|min|intersection|union|prefer:[^\"']+|per-platform|ignore";
  patterns = [
    "\\bbySystem\\b"
    "\\bcombine[\"']?[[:space:]]*[:=][[:space:]]*[\"'](${vocabulary})[\"']"
    "extracted/(${systems}|\\$\\{[^}]*\\})\\.json"
  ];
  # Exits non-zero naming each offending line, or when no file matched.
  scan = pkgs.writeText "extracted-contract-guard.sh" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    cd "$1"
    ${pkgs.findutils}/bin/find . \
      \( -path ./lib/extracted -o -path ./checks/extracted \) -prune -o \
      -type f \( -name '*.nix' -o -name '*.py' -o -name '*.mjs' -o -name '*.js' -o -name '*.sh' -o -name '*.bash' \) \
      -print0 > "$TMPDIR/guard-files"
    mapfile -d "" -t files < "$TMPDIR/guard-files"
    if [ "''${#files[@]}" -eq 0 ]; then
      echo "ERROR: extracted-contract-guard matched zero code files in $1." >&2
      exit 1
    fi
    status=0
    ${pkgs.gnugrep}/bin/grep -HnE ${lib.concatMapStringsSep " " (p: "-e ${lib.escapeShellArg p}") patterns} -- "''${files[@]}" >&2 || status=$?
    case "$status" in
      0)
        echo "FAIL: per-owner code above reads a per-system raw, bySystem, or defines a combine." >&2
        echo "Read facts through lib.extracted (get, getFor, expect); combine rules go in decisions.json." >&2
        exit 1
        ;;
      1) echo "extracted-contract-guard: ''${#files[@]} code files clean" ;;
      *) exit "$status" ;;
    esac
  '';
  # Regular files, as in the flake source: find -type f skips symlinks.
  tree = files:
    pkgs.runCommand "extracted-guard-tree" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${lib.concatStrings (lib.mapAttrsToList (name: text: ''
          install -D -m 644 ${pkgs.writeText (baseNameOf name) text} "$out/${name}"
        '')
        files)}
    '';
  clean = {"packages/fake/default.nix" = "{}\n";};
  controls = {
    empty = {
      files = {"README.md" = "x\n";};
      fails = "zero code files";
    };
    # Every offense below sits where the guard must not look.
    excluded.files =
      clean
      // {
        "checks/extracted/x.nix" = "bySystem\n";
        "lib/extracted/x.nix" = "./extracted/x86_64-linux.json\n";
        "packages/fake/README.md" = "bySystem\n";
      };
    offending = {
      files = clean // {"packages/fake/checks.nix" = "{ combine = \"max\"; }\n";};
      fails = "packages/fake/checks.nix";
    };
  };
  control = label: case: ''
    if bash ${scan} ${tree case.files} 2> "$TMPDIR/${label}"; then
      ${
      if case ? fails
      then ''echo "FAIL: control ${label} passed; it must fail naming ${case.fails}" >&2; exit 1''
      else ":"
    }
    else
      ${
      if case ? fails
      then ''grep -qF ${lib.escapeShellArg case.fails} "$TMPDIR/${label}" || { echo "FAIL: control ${label} does not name ${case.fails}:" >&2; cat "$TMPDIR/${label}" >&2; exit 1; }''
      else ''echo "FAIL: control ${label} failed; it must pass:" >&2; cat "$TMPDIR/${label}" >&2; exit 1''
    }
    fi
  '';
in {
  checks.extracted-contract-guard = pkgs.runCommand "extracted-contract-guard" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${lib.concatStrings (lib.mapAttrsToList control controls)}
    bash ${scan} ${../..} > "$out"
  '';
}
