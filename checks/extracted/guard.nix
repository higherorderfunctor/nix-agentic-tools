# cspell:ignore ENDFILE gsub RLENGTH RSTART
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
# A match must be a real read, not a mention, so comments are stripped to
# end of line first: `#` in every file and `//` in JavaScript and
# TypeScript, each only at line start or after whitespace, so a Nix `//`
# merge, a `"#"` and a `https://` survive. The blind spot is a `#` (or a
# JavaScript `//`) after a space inside a string: the rest of that line goes
# unread. The stripped file is then matched as one whitespace-collapsed
# line, so a `combine` split across lines is still caught.
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
  runner = import ./runner.nix {inherit lib;};
  systems = lib.concatMapStringsSep "|" lib.escapeRegex (import ../../config/systems.nix);
  # gawk regexes; `\y` is a word boundary. `combine` as an attribute name
  # (`=`, not `==`) or an object key (`:`).
  patterns = [
    "\\ybySystem\\y"
    "\\ycombine[\"']?[[:space:]]*[:=]([^=]|$)"
    "extracted/(${systems}|\\$\\{[^}]*\\})\\.json"
  ];
  # Prints each offending file with its first match; exits 1 on any.
  match = pkgs.writeText "extracted-contract-guard.awk" ''
    {
      line = $0
      sub(/(^|[[:space:]])#.*/, "", line)
      if (FILENAME ~ /\.(cjs|js|mjs|ts)$/) sub(/(^|[[:space:]])\/\/.*/, "", line)
      text = text " " line
    }
    ENDFILE {
      gsub(/[[:space:]]+/, " ", text)
      if (match(text, /${lib.concatStringsSep "|" (map (lib.replaceStrings ["/"] ["\\/"]) patterns)}/)) {
        print FILENAME ": " substr(text, RSTART, RLENGTH + 40)
        hit = 1
      }
      text = ""
    }
    END { exit hit }
  '';
  # Exits non-zero naming each offending file, or when no file matched.
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
    offending-hash-string = {
      files = clean // {"packages/fake/hash.nix" = "let marker = \"#\"; in builtins.readFile ./extracted/x86_64-linux.json\n";};
      fails = "packages/fake/hash.nix";
    };
    offending-merge = {
      files = clean // {"packages/fake/merge.nix" = "facts: {} // facts.bySystem\n";};
      fails = "packages/fake/merge.nix";
    };
    offending-multiline = {
      files = clean // {"packages/fake/multiline.nix" = "{ combine\n  = \"max\"; }\n";};
      fails = "packages/fake/multiline.nix";
    };
    offending-ts = {
      files = clean // {"packages/fake/read.ts" = "export const x = facts.bySystem;\n";};
      fails = "packages/fake/read.ts";
    };
    offending-url = {
      files = clean // {"packages/fake/url.nix" = "let url = \"https://example.test\"; in facts.bySystem\n";};
      fails = "packages/fake/url.nix";
    };
  };
  control = label: case:
    runner {
      inherit label;
      command = "bash ${scan} ${tree case.files}";
      names = lib.optional (case ? fails) case.fails;
    };
in {
  checks.extracted-contract-guard = pkgs.runCommand "extracted-contract-guard" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${lib.concatStrings (lib.mapAttrsToList control controls)}
    bash ${scan} ${../..} > "$out"
  '';
}
