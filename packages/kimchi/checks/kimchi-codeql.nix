# The pinned Kimchi release's CodeQL database (lib/codeql.nix), through
# `runQueries` and the one-query pack under ../ql/smoke. The query counts each
# file's process.env reads by name; the rows must include a read in Kimchi's
# own source, one in a minified pi bundle chunk, and the read of
# KIMCHI_WHEEL_SCROLL_LINES that only Kimchi's pi-tui patch adds. So the
# source root, the minified-file flag and the patch step each hold. `$out`
# holds the decoded JSON only. x86_64-linux only, as the engine is.
{
  lib,
  pkgs,
  self,
  ...
}: let
  inherit (self.ciPackages.${pkgs.stdenv.hostPlatform.system}.kimchi.passthru) codeql;
in {
  checks = lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
    kimchi-codeql-database = let
      results = codeql.runQueries {
        name = "smoke";
        queries = codeql.engine.mkQueryPack {
          name = "nix-agentic-tools/kimchi-smoke";
          src = ../ql/smoke;
        };
      };
      pi = "kimchi/node_modules/@earendil-works";
    in
      pkgs.runCommand "kimchi-codeql-database" {nativeBuildInputs = [pkgs.jq];} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        fail() {
          echo "kimchi-codeql-database: $*" >&2
          exit 1
        }
        rows=${results}/EnvReads.json
        # `has <label> <jq filter over one [path, name, reads] row>`
        has() {
          jq -e --arg pi ${pi} "any(.[\"#select\"].tuples[]; $2)" "$rows" > /dev/null || fail "no process.env read $1"
        }
        has "in Kimchi's own source" '.[0] | startswith("kimchi/src/")'
        has "in a minified pi bundle chunk" '.[0] | startswith("\($pi)/pi-coding-agent/dist/bundle/chunks/")'
        has "of KIMCHI_WHEEL_SCROLL_LINES in pi-tui, which Kimchi's patch adds" '(.[0] | startswith("\($pi)/pi-tui/")) and .[1] == "KIMCHI_WHEEL_SCROLL_LINES"'
        cp -R ${results} "$out"
        other="$(find "$out" ! -type d ! -name '*.json')"
        [ -z "$other" ] || fail "\$out holds more than JSON: $other"
        find "$out" -type f -name '*.json' -exec jq empty {} +
        jq -c '.["#select"].tuples | length' "$rows"
      '';
  };
}
