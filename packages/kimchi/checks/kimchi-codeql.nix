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
  environment = import ../extract/environment.nix {
    inherit codeql pkgs;
    # The release's accepted sites must not become stale rows in a fixture.
    annotations = pkgs.writeText "kimchi-environment-fixture-annotations.json" "{}";
  };
in {
  checks = lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
    # `runQueries` and the one-query pack under ../ql/smoke. The query counts
    # each file's process.env reads by name. The patched adapter's
    # KIMCHI_MANAGES_MCP_PROJECT_TRUST row proves the source root and patch step.
    kimchi-codeql-database = let
      results = codeql.runQueries {
        name = "smoke";
        queries = pkgs.ai.devTools.codeql.mkQueryPack {
          name = "nix-agentic-tools/kimchi-smoke";
          src = ../ql/smoke;
        };
      };
    in
      pkgs.runCommand "kimchi-codeql-database" {nativeBuildInputs = [pkgs.jq];} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        fail() {
          echo "kimchi-codeql-database: $*" >&2
          exit 1
        }
        cp -R ${results} "$out"
        # The one-query pack must publish its decoded result and no sidecars.
        outputs=$(find "$out" -mindepth 1 -printf '%P\n')
        [ "$outputs" = EnvReads.json ] || fail "expected only EnvReads.json in \$out, found: $outputs"
        rows="$out/EnvReads.json"
        jq -e 'any(.["#select"].tuples[]; (.[0] | startswith("kimchi/node_modules/pi-mcp-adapter/")) and .[1] == "KIMCHI_MANAGES_MCP_PROJECT_TRUST")' "$rows" > /dev/null \
          || fail "no process.env read of KIMCHI_MANAGES_MCP_PROJECT_TRUST in the patched MCP adapter"
      '';

    # The environment pack and transform over each tree under
    # ./fixtures/codeql-environment, laid out like the real source root and
    # extracted by the same script. A case with `expected.json` must transform
    # to exactly that surface; a case with `expected-failures` must fail the
    # transform with every line of it in the message. The shapes are the ones
    # the fact's producer accepted and refused (../docs/kimchi-codeql-environment.md).
    kimchi-codeql-environment-guard = let
      fixtures = ./fixtures/codeql-environment;
      reviewedCases = [
        "fail-order" # Treating a late or deferred write as an unconditional launch overwrite.
        "fail-shapes" # Guessing computed names or names from escaped environment objects.
        "fail-sources" # Picking an ambiguous constant or ignoring a read in an imported module.
        "overwrites" # Losing the distinction between fixed launch values and consumer-overridable names.
        "reads" # Dropping supported reads or attributing carried dependency reads to Kimchi.
      ];
      directories = builtins.attrNames (lib.filterAttrs (_: type: type == "directory") (builtins.readDir fixtures));
      cases = assert lib.assertMsg (directories == reviewedCases) "kimchi-codeql-environment-guard: fixture inventory differs from the reviewed cases"; reviewedCases;
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
            [ -s "$fixture/expected-failures" ] || fail "$case: negative fixture must name the expected failures"
            if output=$(kimchi-codeql-environment "$TMPDIR/$case/results" 2>&1); then
              fail "$case: the transform accepted the tree"
            fi
            while IFS= read -r expected || [ -n "$expected" ]; do
              [ -n "$expected" ] || fail "$case: expected failure must not be blank"
              case "$output" in
                *"$expected"*) ;;
                *) echo "$output" >&2; fail "$case: the failure does not say: $expected" ;;
              esac
            done < "$fixture/expected-failures"
            echo "$case: refused, saying: $output"
          fi
        done > "$out"
      '';

    # Feed decoded query results directly to the release transform. A reviewed
    # key must have a non-blank reason and exactly its reviewed number of sites.
    kimchi-codeql-environment-review-guard = let
      key = "kimchi/src/env.ts#key[VarRef]";
      queryResults = tuples: builtins.toJSON {"#select" = {inherit tuples;};};
      checkReview = name: {
        columns,
        expectedFailure ? null,
        reason ? "One reviewed computed read.",
      }: let
        annotations = pkgs.writeText "kimchi-environment-${name}-annotations.json" (builtins.toJSON {
          environmentUnresolved.${key} = {
            inherit reason;
            sites = 1;
          };
        });
        reviewed = import ../extract/environment.nix {inherit annotations codeql pkgs;};
        reads = queryResults (map (column: ["fail" "unresolved computed environment read: ${key}" "kimchi/src/env.ts:3:${toString column}"]) columns);
        run = ''${lib.getExe reviewed.transform} "$TMPDIR"'';
      in ''
        printf '%s\n' ${lib.escapeShellArg reads} > "$TMPDIR/EnvironmentReads.json"
        ${
          if expectedFailure == null
          then ''${run} | jq -e '. == {variables: {}}' > /dev/null || fail "${name}: expected an empty surface"''
          else ''
            if output=$(${run} 2>&1); then
              fail '${name}: accepted a review that should be refused'
            fi
            case "$output" in
              *${lib.escapeShellArg expectedFailure}*) ;;
              *) fail "${name}: unexpected diagnostic: $output" ;;
            esac
          ''
        }
        echo '${name}: as expected'
      '';
      cases = {
        # An explanation consisting only of whitespace must not waive a read.
        blank-reason = {
          columns = [5];
          expectedFailure = "environmentUnresolved rows need a non-blank reason: ${key}";
          reason = " ";
        };
        # A review for one occurrence cannot waive a second occurrence.
        duplicate-site = {
          columns = [5 23];
          expectedFailure = "unresolved site count changed; review the row: ${key} (expected 1 unresolved sites, got 2)";
        };
        # One exact reviewed site succeeds without publishing a made-up key.
        reviewed-site.columns = [5];
        # An annotation cannot outlive the unresolved read it reviewed.
        stale-row = {
          columns = [];
          expectedFailure = "stale environmentUnresolved rows; delete the stale row: ${key}";
        };
      };
    in
      pkgs.runCommand "kimchi-codeql-environment-review-guard" {nativeBuildInputs = [pkgs.jq];} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        fail() {
          echo "kimchi-codeql-environment-review-guard: $*" >&2
          exit 1
        }
        printf '%s\n' ${lib.escapeShellArg (queryResults [])} > "$TMPDIR/LaunchOverwrites.json"
        (
          ${lib.concatStrings (lib.mapAttrsToList checkReview cases)}
        ) > "$out"
      '';
  };
}
