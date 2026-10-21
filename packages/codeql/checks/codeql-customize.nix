# `customizePackage`, `mkQueryPack` and `mkModelPack` on the javascript engine,
# the one CI builds. Each check creates a database of a fixture tree under
# ./fixtures and analyzes it; `$out` holds the result rows only. See
# docs/codeql.md.
{
  lib,
  pkgs,
  self,
  ...
}: let
  engine = self.ciPackages.${pkgs.stdenv.hostPlatform.system}.codeql-javascript;
  queries = engine.mkQueryPack {
    name = "nix-agentic-tools/fixture-queries";
    src = ./fixtures/queries;
  };
  sinkQueries = engine.mkQueryPack {
    name = "nix-agentic-tools/fixture-sinks";
    src = ./fixtures/model-queries;
  };
  models = engine.mkModelPack {
    name = "nix-agentic-tools/fixture-models";
    src = ./fixtures/models;
  };
  marker = pkgs.writeShellApplication {
    name = "codeql-fixture-marker";
    bashOptions = ["errexit" "errtrace" "functrace" "nounset" "pipefail"];
    text = ''
      shopt -s inherit_errexit 2>/dev/null || :
      echo ran > "$CODEQL_FIXTURE_MARK"
    '';
  };

  # `database <codeql> <name> <tree> <args...>` creates $TMPDIR/<name> from a
  # writable copy of <tree>; `results <codeql> <database> <pack>` prints one
  # sorted `<rule> <file>:<line> <message>` line per result.
  check = name: body:
    pkgs.runCommand name {nativeBuildInputs = [pkgs.jq];} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      export HOME="$TMPDIR" LC_ALL=C
      fail() {
        echo "${name}: $*" >&2
        exit 1
      }
      database() {
        cp -R --no-preserve=mode "$3" "$TMPDIR/$2-src"
        if ! "$1" database create "$TMPDIR/$2" --language=javascript --source-root="$TMPDIR/$2-src" "''${@:4}" > "$TMPDIR/$2.log" 2>&1; then
          cat "$TMPDIR/$2.log" >&2
          return 1
        fi
      }
      results() {
        "$1" database analyze "$2" "$3" --rerun --format=sarif-latest --output="$TMPDIR/results.sarif" >&2
        jq -r '.runs[].results[] | "\(.ruleId) \(.locations[0].physicalLocation.artifactLocation.uri):\(.locations[0].physicalLocation.region.startLine) \(.message.text)"' "$TMPDIR/results.sarif" | sort
      }
      ${body}
    '';
in {
  checks = lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
    # A precompiled two-query pack resolves by name with no flag, also beside a
    # consumer's own config file, and its queries return the fixture rows. The
    # TypeScript file is extracted only with the engine's Node.
    codeql-custom-query-pack = let
      custom = engine.customizePackage {queries = [queries];};
    in
      check "codeql-custom-query-pack" ''
        plain=${engine}/bin/codeql
        codeql=${custom}/bin/codeql
        pack=nix-agentic-tools/fixture-queries
        [ -n "$(find ${queries} -name '*.qlx' -print -quit)" ] || fail "mkQueryPack left no precompiled .qlx"
        "$plain" resolve packs > "$TMPDIR/plain-packs" 2>&1
        ! grep -q " $pack@" "$TMPDIR/plain-packs" || fail "the plain engine resolves $pack"
        "$codeql" resolve packs > "$TMPDIR/packs" 2>&1
        grep -q " $pack@" "$TMPDIR/packs" || fail "the customized engine does not resolve $pack"
        printf -- '--threads 1\n' > "$TMPDIR/consumer-config"
        CODEQL_CONFIG_FILE="$TMPDIR/consumer-config" "$codeql" resolve packs > "$TMPDIR/merged-packs" 2>&1
        grep -q " $pack@" "$TMPDIR/merged-packs" || fail "a consumer config file hides $pack"
        printf -- '--additional-packs %s\n' "$TMPDIR" > "$TMPDIR/clashing-config"
        if CODEQL_CONFIG_FILE="$TMPDIR/clashing-config" "$codeql" resolve packs 2> "$TMPDIR/clash.err"; then
          fail "a consumer --additional-packs line was accepted"
        fi
        grep -q customizePackage "$TMPDIR/clash.err" || fail "the clash message does not name customizePackage"
        database "$codeql" db ${./fixtures/project} --build-mode=none
        grep -qF "Found Node.js at: ${lib.getExe engine.nodejs}" "$TMPDIR/db.log" || fail "the extractor did not run the engine's Node"
        results "$codeql" "$TMPDIR/db" "$pack" > "$out"
        diff - "$out" <<'EOF' || fail "unexpected rows"
        nix-agentic-tools/named-calls double.ts:5 call to double
        nix-agentic-tools/named-calls greet.js:5 call to greet
        nix-agentic-tools/named-functions double.ts:1 function double
        nix-agentic-tools/named-functions greet.js:1 function greet
        EOF
      '';

    # `extraPackages` reach `database create --command`; the plain engine
    # cannot find the program.
    codeql-extra-packages = let
      custom = engine.customizePackage {extraPackages = [marker];};
    in
      check "codeql-extra-packages" ''
        export CODEQL_FIXTURE_MARK="$TMPDIR/mark"
        if database ${engine}/bin/codeql plain ${./fixtures/project} --command=codeql-fixture-marker 2> /dev/null; then
          fail "the plain engine ran codeql-fixture-marker"
        fi
        [ ! -e "$CODEQL_FIXTURE_MARK" ] || fail "the plain engine wrote the mark"
        database ${custom}/bin/codeql db ${./fixtures/project} --command=codeql-fixture-marker
        grep -qx ran "$CODEQL_FIXTURE_MARK" || fail "codeql-fixture-marker did not run"
        echo "codeql-fixture-marker ran" > "$out"
      '';

    # A sinkModel row of kind request-forgery makes `request` from the made-up
    # `fakehttp` a RequestForgery::Sink. The models are added by customizing
    # the customized package, so the check also covers appending.
    codeql-model-pack-mutation = let
      queriesOnly = engine.customizePackage {queries = [sinkQueries];};
      withModels = queriesOnly.customizePackage {models = [models];};
    in
      check "codeql-model-pack-mutation" ''
        pack=nix-agentic-tools/fixture-sinks
        database ${queriesOnly}/bin/codeql db ${./fixtures/fakehttp-project} --build-mode=none
        results ${queriesOnly}/bin/codeql "$TMPDIR/db" "$pack" > "$TMPDIR/without"
        [ ! -s "$TMPDIR/without" ] || fail "sinks without the model pack: $(cat "$TMPDIR/without")"
        results ${withModels}/bin/codeql "$TMPDIR/db" "$pack" > "$out"
        diff - "$out" <<'EOF' || fail "unexpected rows"
        nix-agentic-tools/request-forgery-sinks client.js:3 request-forgery sink
        EOF
      '';
  };
}
