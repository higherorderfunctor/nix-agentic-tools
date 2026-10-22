# The pinned Kimchi release's CodeQL database (lib/codeql.nix), and the
# environment query pack over fixture trees. x86_64-linux only, as the engine
# is. `$out` of each check holds text or JSON only.
{
  lib,
  pkgs,
  self,
  ...
}: let
  inherit (self.ciPackages.${pkgs.stdenv.hostPlatform.system}.kimchi.passthru) codeql;
  environment = import ../extract/environment.nix {inherit codeql pkgs;};
in {
  checks = lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
    # `runQueries` and the one-query pack under ../ql/smoke. The query counts
    # each file's process.env reads by name; the rows must include a read in
    # Kimchi's own source, one in a minified pi bundle chunk, and the read of
    # KIMCHI_WHEEL_SCROLL_LINES that only Kimchi's pi-tui patch adds. So the
    # source root, the minified-file flag and the patch step each hold.
    kimchi-codeql-database = let
      results = codeql.runQueries {
        name = "smoke";
        queries = pkgs.ai.devTools.codeql.mkQueryPack {
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

    # The environment pack and transform over each tree under
    # ./fixtures/codeql-environment, laid out like the real source root and
    # extracted by the same script. A case with `expected.json` must transform
    # to exactly that surface; a case with `expected-failures` must fail the
    # transform with every line of it in the message. The shapes are the ones
    # the fact's producer accepted and refused (../docs/kimchi-codeql-environment.md).
    kimchi-codeql-environment-guard = let
      fixtures = ./fixtures/codeql-environment;
      cases = builtins.attrNames (lib.filterAttrs (_: type: type == "directory") (builtins.readDir fixtures));
    in
      pkgs.runCommand "kimchi-codeql-environment-guard" {
        nativeBuildInputs = [
          codeql.createDatabase
          (codeql.mkQueryRunner {inherit (environment) queries;})
          environment.transform
          pkgs.jq
        ];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        export HOME="$TMPDIR"
        fail() {
          echo "kimchi-codeql-environment-guard: $*" >&2
          exit 1
        }
        for case in ${lib.escapeShellArgs cases}; do
          fixture=${fixtures}/"$case"
          kimchi-codeql-create-database "$TMPDIR/$case" "$fixture/source" > "$TMPDIR/$case.log" 2>&1 || { cat "$TMPDIR/$case.log" >&2; fail "$case: database creation failed"; }
          kimchi-codeql-run-queries "$TMPDIR/$case/db" "$TMPDIR/$case/results"
          if [ -f "$fixture/expected.json" ]; then
            kimchi-codeql-environment "$TMPDIR/$case/results" > "$TMPDIR/$case/environment.json"
            # The repository formatter lays expected.json out its own way.
            jq -S . "$fixture/expected.json" > "$TMPDIR/$case/expected.json"
            if ! cmp -s "$TMPDIR/$case/environment.json" "$TMPDIR/$case/expected.json"; then
              diff -u "$TMPDIR/$case/expected.json" "$TMPDIR/$case/environment.json" >&2 || :
              fail "$case: the surface differs from expected.json"
            fi
            echo "$case: $(jq '.variables | length' "$TMPDIR/$case/environment.json") variables, as expected"
          else
            if output=$(kimchi-codeql-environment "$TMPDIR/$case/results" 2>&1); then
              fail "$case: the transform accepted the tree"
            fi
            while IFS= read -r expected; do
              case "$output" in
                *"$expected"*) ;;
                *) echo "$output" >&2; fail "$case: the failure does not say: $expected" ;;
              esac
            done < "$fixture/expected-failures"
            echo "$case: refused, saying: $output"
          fi
        done > "$out"
      '';
  };
}
