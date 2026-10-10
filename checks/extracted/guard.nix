# The facts contract's guard: owners supply data and extractors only. Every
# tracked file outside lib/extracted/ and checks/extracted/ is scanned for
# the three things only those directories may do: read a per-system raw
# path, reach into `bySystem`, or define a `combine` attribute.
#
# Every regular file is scanned except Markdown, which describes the
# contract (generated instruction projections included), and JSON, which is
# data: decisions.json is where combine rules belong, and sidecars hold
# measured values. Symlinks are skipped; they point into the store.
#
# A match must be a real read, not a mention: `#` and `//` comments are
# stripped to end of line first. That is an approximation (a `#` or `//`
# inside a string also ends the line), and it only ever misses, never
# refuses.
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
  # gawk regexes; `\y` is a word boundary. `combine` as an attribute name
  # (`=`, not `==`) or an object key (`:`).
  patterns = [
    "\\ybySystem\\y"
    "\\ycombine[\"']?[[:space:]]*[:=]([^=]|$)"
    "extracted/(${systems}|\\$\\{[^}]*\\})\\.json"
  ];
  # Prints each offending line; exits 1 on any.
  match = pkgs.writeText "extracted-contract-guard.awk" ''
    {
      line = $0
      sub(/#.*/, "", line)
      sub(/\/\/.*/, "", line)
      if (line ~ /${lib.concatStringsSep "|" (map (lib.replaceStrings ["/"] ["\\/"]) patterns)}/) {
        print FILENAME ":" FNR ": " $0
        hit = 1
      }
    }
    END { exit hit }
  '';
  # Exits non-zero naming each offending line, or when no file matched.
  scan = pkgs.writeText "extracted-contract-guard.sh" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    cd "$1"
    ${pkgs.findutils}/bin/find . \
      \( -path ./lib/extracted -o -path ./checks/extracted \) -prune -o \
      -type f ! -name '*.md' ! -name '*.json' \
      -print0 > "$TMPDIR/guard-files"
    mapfile -d "" -t files < "$TMPDIR/guard-files"
    if [ "''${#files[@]}" -eq 0 ]; then
      echo "ERROR: extracted-contract-guard matched zero files in $1." >&2
      exit 1
    fi
    status=0
    ${pkgs.gawk}/bin/gawk -f ${match} -- "''${files[@]}" >&2 || status=$?
    case "$status" in
      0) echo "extracted-contract-guard: ''${#files[@]} files clean" ;;
      1)
        echo "FAIL: per-owner code above reads a per-system raw, bySystem, or defines a combine." >&2
        echo "Read facts through lib.extracted (get, getFor, expect); combine rules go in decisions.json." >&2
        exit 1
        ;;
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
      fails = "zero files";
    };
    # Every mention below is one the guard must let through.
    excluded.files =
      clean
      // {
        "checks/extracted/x.nix" = "bySystem\n";
        "lib/extracted/x.nix" = "./extracted/x86_64-linux.json\n";
        "packages/fake/README.md" = "bySystem\n";
        "packages/fake/comment.nix" = "{} # reads bySystem\n";
        "packages/fake/extracted/decisions.json" = "{\"models\": {\"combine\": \"max\"}}\n";
      };
    offending = {
      files = clean // {"packages/fake/checks.nix" = "let rule = \"max\"; in { combine = rule; }\n";};
      fails = "packages/fake/checks.nix";
    };
    offending-ts = {
      files = clean // {"packages/fake/read.ts" = "export const x = facts.bySystem;\n";};
      fails = "packages/fake/read.ts";
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
