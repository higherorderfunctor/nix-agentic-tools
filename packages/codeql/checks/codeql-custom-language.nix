# A tiny independent language: no Nix extractor, evaluation or generated AST.
{
  lib,
  pkgs,
  self,
  ...
}: let
  inherit (pkgs.stdenv.hostPlatform) system;
  engine = self.ciPackages.${system}.codeql-javascript;
  bare = self.ciPackages.${system}.codeql-bare;
  fixture = ./fixtures/custom-language;
  extractor = {
    language = "fixture";
    schema = "fixture.dbscheme";
    src = fixture + "/extractor";
  };
  library = {
    language = "fixture";
    name = "nix-agentic-tools/fixture-all";
    schema = "fixture.dbscheme";
    src = fixture + "/library";
  };
  query = pkgs.ai.devTools.codeql.mkQueryPack {
    language = "fixture";
    name = "nix-agentic-tools/fixture-custom-query";
    src = fixture + "/queries";
  };
  capability = {
    extractors = [extractor];
    libraries = [library];
  };
  custom = engine.customizePackage capability;
  compiled = (custom.customizePackage {queries = [query];}).customizePackage capability;
  # No build is needed to establish capability admission or rejection.
  accepts = target: spec: (builtins.tryEval (target.customizePackage spec).drvPath).success;
  failures = lib.filter (value: value != null) [
    (
      if accepts bare (capability // {queries = [query];})
      then null
      else "bare refused a complete custom capability"
    )
    (
      if accepts engine {queries = [query];}
      then "query admitted without its custom capability"
      else null
    )
    (
      if
        accepts engine {
          extractors = [extractor];
          queries = [query];
        }
      then "extractor alone admitted the query"
      else null
    )
    (
      if
        accepts engine {
          libraries = [library];
          queries = [query];
        }
      then "library alone admitted the query"
      else null
    )
    (
      if
        accepts engine (capability
          // {
            libraries = [(library // {language = "other";})];
            queries = [query];
          })
      then "different languages established a capability"
      else null
    )
    (
      if
        accepts engine (capability
          // {
            libraries = [(library // {schema = "other.dbscheme";})];
            queries = [query];
          })
      then "different schemas established a capability"
      else null
    )
    (
      if accepts engine (capability // {extractors = [extractor (extractor // {inherit (library) src;})];})
      then "two extractors claimed one language"
      else null
    )
    (
      if accepts engine (capability // {libraries = [library (library // {name = "other/fixture-all";})];})
      then "two libraries claimed one language"
      else null
    )
  ];
  # These inputs are derivations, so validating their bytes must not need IFD.
  changedLibrary = replacement:
    pkgs.runCommand "codeql-fixture-library-changed" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      cp -R --no-preserve=mode ${library.src} "$out"
      ${replacement}
    '';
  badDescriptor = pkgs.testers.testBuildFailure (engine.customizePackage (capability
    // {
      extractors = [(extractor // {language = "wrong";})];
      libraries = [(library // {language = "wrong";})];
    }));
  badSchema = pkgs.testers.testBuildFailure (engine.customizePackage (capability
    // {
      libraries = [(library // {src = changedLibrary ''printf 'different_values(string value: string ref);\n' > "$out/fixture.dbscheme"'';})];
    }));
  badName = pkgs.testers.testBuildFailure (engine.customizePackage (capability
    // {
      libraries = [(library // {name = "wrong/fixture-all";})];
    }));
in {
  checks = lib.optionalAttrs (system == "x86_64-linux") {
    codeql-custom-language = assert lib.assertMsg (failures == []) (lib.concatStringsSep "\n" failures);
      pkgs.runCommand "codeql-custom-language" {nativeBuildInputs = [pkgs.jq pkgs.yq-go];} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME" "$TMPDIR/run"
        fail() { echo "codeql-custom-language: $*" >&2; exit 1; }
        codeql=${compiled}/bin/codeql
        "$codeql" resolve languages --format=json > "$TMPDIR/languages"
        jq -e 'has("fixture") and has("javascript")' "$TMPDIR/languages" > /dev/null || fail "custom or bundled extractor lost"
        "$codeql" resolve packs > "$TMPDIR/packs" 2>&1
        grep -q ' nix-agentic-tools/fixture-all@' "$TMPDIR/packs" || fail "custom library not resolved"
        grep -q ' nix-agentic-tools/fixture-custom-query@' "$TMPDIR/packs" || fail "appended query not resolved"
        pack=${builtins.head compiled.packs.queries}
        [ -n "$(find "$pack" -name '*.qlx' -print -quit)" ] || fail "custom query was not precompiled"
        # The compiled manifest must depend on the declared identity, never a
        # synthesized codeql/fixture-all, even though javascript is bundled.
        yq -o=json . "$pack/qlpack.yml" | jq -e '.dependencies | has("nix-agentic-tools/fixture-all") and (has("codeql/fixture-all") | not)' > /dev/null || fail "custom dependency identity lost"
        printf -- '--threads 1\n' > "$TMPDIR/consumer"
        XDG_RUNTIME_DIR="$TMPDIR/run" CODEQL_CONFIG_FILE="$TMPDIR/consumer" "$codeql" resolve languages --format=json > "$TMPDIR/merged"
        jq -e 'has("fixture")' "$TMPDIR/merged" > /dev/null || fail "consumer config hides extractor"
        generated=("$TMPDIR"/run/codeql-config-*)
        [ "''${#generated[@]}" = 1 ] || fail "expected one merged config"
        CODEQL_CONFIG_FILE="''${generated[0]}" "$codeql" resolve packs > "$TMPDIR/nested" 2>&1
        grep -q ' nix-agentic-tools/fixture-all@' "$TMPDIR/nested" || fail "child config hides library"
        # Generated config owns --search-path as well as --additional-packs.
        printf -- '  --search-path %s\n' "$TMPDIR" > "$TMPDIR/clash"
        status=0
        CODEQL_CONFIG_FILE="$TMPDIR/clash" "$codeql" resolve languages > /dev/null 2> "$TMPDIR/clash.err" || status=$?
        [ "$status" = 2 ] && grep -q customizePackage "$TMPDIR/clash.err" || fail "search-path conflict was not explained"
        grep -Eqi 'extractor.*wrong|wrong.*extractor' ${badDescriptor}/testBuildFailure.log || fail "extractor mismatch failed for another reason"
        grep -Eqi 'schema.*(mismatch|differ)|(mismatch|differ).*schema' ${badSchema}/testBuildFailure.log || fail "schema mutation failed for another reason"
        grep -q 'wrong/fixture-all' ${badName}/testBuildFailure.log || fail "manifest mismatch failed for another reason"
        printf '%s\n' 'custom extractor and library resolved; custom query precompiled' 'schema and manifest mismatches refused; inherited and child configs preserved' | tee "$out"
      '';
  };
}
