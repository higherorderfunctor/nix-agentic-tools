# `customizePackage` on the javascript engine, the one CI builds, with pack
# specs from `ai.devTools.codeql.mkQueryPack` and `mkModelPack`. Each check
# that builds creates a database of a fixture tree under ./fixtures and
# analyzes it; `$out` holds the result rows only. `codeql-pack-specs` only
# evaluates engines. See docs/customize.md.
{
  harness,
  lib,
  pkgs,
  self,
  ...
}: let
  inherit (harness) checkRows rejectsChange;
  inherit (pkgs.stdenv.hostPlatform) system;
  packages = self.ciPackages.${system};
  engine = packages.codeql-javascript;
  # The namespace as a consumer reads it from the package set.
  codeql = pkgs.ai.devTools.codeql;
  fetchModels = codeql.mkModelPack {
    name = "nix-agentic-tools/fixture-fetch-models";
    src = ./fixtures/fetch-models;
  };
  models = codeql.mkModelPack {
    name = "nix-agentic-tools/fixture-models";
    src = ./fixtures/models;
  };
  queries = codeql.mkQueryPack {
    name = "nix-agentic-tools/fixture-queries";
    src = ./fixtures/queries;
  };
  sinkQueries = codeql.mkQueryPack {
    name = "nix-agentic-tools/fixture-sinks";
    src = ./fixtures/model-queries;
  };
  # Record what the nested CodeQL resolves with inherited config.
  marker = pkgs.writeShellApplication {
    name = "codeql-fixture-marker";
    bashOptions = ["errexit" "errtrace" "functrace" "nounset" "pipefail"];
    text = ''
      shopt -s inherit_errexit 2>/dev/null || :
      "$CODEQL_NESTED" resolve packs > "$CODEQL_FIXTURE_PACKS" 2>&1
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
      # Drive the real wrapper; an unrelated CodeQL error is not a refusal.
      refuses_config() {
        local codeql="$1" config="$2" owned_options="$3" status=0
        CODEQL_CONFIG_FILE="$config" "$codeql" resolve packs > "$TMPDIR/refusal.log" 2>&1 || status=$?
        [ "$status" = 2 ] || fail "$(basename "$config"): exited $status, expected 2: $(cat "$TMPDIR/refusal.log")"
        grep -Fxq -- "codeql: $config sets $owned_options, which this customized codeql sets from customizePackage." "$TMPDIR/refusal.log" || fail "$(basename "$config"): not a wrapper pack conflict: $(cat "$TMPDIR/refusal.log")"
      }
      ${body}
    '';
in {
  checks = lib.optionalAttrs (pkgs.stdenv.hostPlatform.system == "x86_64-linux") {
    # Precompiled siblings must both be shipped, including the calls query's
    # imported .qll, and both must see the JavaScript and TypeScript inputs.
    # Test config inputs through the real wrapper, not by grepping its source.
    codeql-custom-query-pack = let
      custom = engine.customizePackage {queries = [queries];};
    in
      check "codeql-custom-query-pack" ''
        codeql=${custom}/bin/codeql
        pack=nix-agentic-tools/fixture-queries
        [ -n "$(find ${builtins.head custom.packs.queries} -name '*.qlx' -print -quit)" ] || fail "the realized query pack has no precompiled .qlx"
        second=nix-agentic-tools/fixture-second
        mkdir -p "$TMPDIR/second" "$TMPDIR/home/.config/codeql"
        printf 'name: %s\nversion: 0.0.0\n' "$second" > "$TMPDIR/second/qlpack.yml"
        # When checking membership, require our pack; consumer configs must
        # also retain their --search-path, which our pack alone cannot prove.
        resolves() {
          local label="$1" output="$TMPDIR/$1-packs"
          "$codeql" resolve packs > "$output" 2>&1 || fail "$label: codeql failed: $(cat "$output")"
          if [ "$2" = status ]; then return; fi
          grep -Fq " $pack@" "$output" || fail "$label: lost $pack"
          if [ "$2" = both ]; then
            grep -Fq " $second@" "$output" || fail "$label: lost the consumer's --search-path"
          fi
        }
        ln -s /dev/null "$TMPDIR/null-link"
        printf -- '--search-path %s\n' "$TMPDIR/second" > "$TMPDIR/consumer-config"
        printf -- '--search-path %s' "$TMPDIR/second" > "$TMPDIR/no-newline-config"
        printf -- '# --additional-packs comes from customizePackage\n--search-path %s\n' "$TMPDIR/second" > "$TMPDIR/comment-config"
        cp "$TMPDIR/consumer-config" "$TMPDIR/home/.config/codeql/config"
        # A comment is not a clash; an explicit file does not need a final
        # newline; HOME supplies the file when no environment override is set.
        for config in comment no-newline; do
          CODEQL_CONFIG_FILE="$TMPDIR/$config-config" resolves "$config" both
        done
        HOME="$TMPDIR/home" resolves home both
        # A differently named link to the null device must not be read as a
        # consumer file.
        CODEQL_CONFIG_FILE="$TMPDIR/null-link" resolves null-link ours
        # The merged config outlives the wrapper under a name from its content:
        # two runs leave one file, the consumer's line before ours, and no
        # mktemp file behind.
        mkdir "$TMPDIR/run"
        XDG_RUNTIME_DIR="$TMPDIR/run" CODEQL_CONFIG_FILE="$TMPDIR/consumer-config" resolves runtime-first status
        XDG_RUNTIME_DIR="$TMPDIR/run" CODEQL_CONFIG_FILE="$TMPDIR/consumer-config" resolves runtime-second both
        persisted=("$TMPDIR"/run/codeql-config-*)
        [ "''${#persisted[@]}" = 1 ] && [ -f "''${persisted[0]}" ] || fail "two runs left $(ls "$TMPDIR/run"), not one codeql-config-* file"
        theirsAt="$(grep -nm1 -- '^--search-path ' "''${persisted[0]}" | cut -d: -f1)"
        oursAt="$(grep -nm1 -- '^--additional-packs ' "''${persisted[0]}" | cut -d: -f1)"
        [ -n "$theirsAt" ] && [ -n "$oursAt" ] && [ "$theirsAt" -lt "$oursAt" ] || fail "the merged config does not hold the consumer's line before ours: $(cat "''${persisted[0]}")"
        [ -z "$(find "$TMPDIR/run" -name 'codeql-config.*')" ] || fail "the wrapper left a mktemp file: $(ls "$TMPDIR/run")"
        # Each run repairs a stale file at the same path, not just a file
        # that happens to make both packs resolve.
        cp "''${persisted[0]}" "$TMPDIR/original-config"
        echo JUNK > "''${persisted[0]}"
        XDG_RUNTIME_DIR="$TMPDIR/run" CODEQL_CONFIG_FILE="$TMPDIR/consumer-config" resolves runtime-rewrite both
        cmp -s "$TMPDIR/original-config" "''${persisted[0]}" || fail "a run did not restore ''${persisted[0]}"
        # Feeding the generated file back must not publish a second merge.
        mkdir "$TMPDIR/reused"
        XDG_RUNTIME_DIR="$TMPDIR/reused" CODEQL_CONFIG_FILE="''${persisted[0]}" resolves generated both
        [ -z "$(ls -A "$TMPDIR/reused")" ] || fail "a generated config was merged again"

        # Fallback has to publish in TMPDIR, not merely resolve the packs.
        fallbackDir="$TMPDIR/fallback"
        mkdir "$fallbackDir"
        XDG_RUNTIME_DIR="$TMPDIR/missing" CODEQL_CONFIG_FILE="$TMPDIR/consumer-config" TMPDIR="$fallbackDir" resolves runtime-missing both
        fallback=("$fallbackDir"/codeql-config-*)
        [ "''${#fallback[@]}" = 1 ] && [ -f "''${fallback[0]}" ] || fail "no unique merged config in TMPDIR after XDG_RUNTIME_DIR fallback"

        # An indented override still sets the option. Appending an override
        # beside our own line must not pass as an already merged config.
        { cat "''${persisted[0]}"; printf -- '--additional-packs %s\n' "$TMPDIR"; } > "$TMPDIR/generated-clash-config"
        printf -- '  --additional-packs %s\n' "$TMPDIR" > "$TMPDIR/indented-config"
        for config in generated-clash indented; do
          refuses_config "$codeql" "$TMPDIR/$config-config" --additional-packs
        done
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

    # The customized engine's build command must find the marker on PATH.
    # The marker launches another customized CodeQL, exercising inherited
    # config both with and without a consumer file.
    codeql-extra-packages = let
      custom = engine.customizePackage {
        extraPackages = [marker];
        queries = [queries];
      };
    in
      check "codeql-extra-packages" ''
        pack=nix-agentic-tools/fixture-queries
        export CODEQL_FIXTURE_PACKS="$TMPDIR/nested-packs" CODEQL_NESTED=${custom}/bin/codeql
        printf -- '--threads 1\n' > "$TMPDIR/consumer-config"
        # A nested invocation inherits the wrapper's config in both forms;
        # losing the generated file only affects the consumer-config row.
        for config in consumer default; do
          rm -f "$CODEQL_FIXTURE_PACKS"
          if [ "$config" = consumer ]; then
            export CODEQL_CONFIG_FILE="$TMPDIR/consumer-config"
          else
            unset CODEQL_CONFIG_FILE
          fi
          database ${custom}/bin/codeql "$config" ${./fixtures/project} --command=codeql-fixture-marker
          grep -Fq " $pack@" "$CODEQL_FIXTURE_PACKS" || fail "$config: nested codeql does not resolve $pack"
        done
        echo "codeql-fixture-marker ran and resolved $pack" > "$out"
      '';

    # A sinkModel row of kind request-forgery makes `request` from the made-up
    # `fakehttp` a RequestForgery::Sink, and a second model pack does the same
    # for `fetchUrl`. Each model pack is added by customizing the customized
    # package, so the check also covers appending and the aggregate pack. A
    # consumer --model-packs line is refused once there are models, also beside
    # the lines of a merged config, which is otherwise used as it is.
    codeql-model-pack-mutation = let
      queriesOnly = engine.customizePackage {queries = [sinkQueries];};
      withModels = (queriesOnly.customizePackage {models = [models];}).customizePackage {models = [fetchModels];};
    in
      check "codeql-model-pack-mutation" ''
        pack=nix-agentic-tools/fixture-sinks
        database ${queriesOnly}/bin/codeql db ${./fixtures/fakehttp-project} --build-mode=none
        results ${queriesOnly}/bin/codeql "$TMPDIR/db" "$pack" > "$TMPDIR/without"
        [ ! -s "$TMPDIR/without" ] || fail "sinks without the model pack: $(cat "$TMPDIR/without")"
        printf -- '--model-packs %s\n' "$pack" > "$TMPDIR/clashing-config"
        refuses_config ${withModels}/bin/codeql "$TMPDIR/clashing-config" '--additional-packs or --model-packs'
        results ${withModels}/bin/codeql "$TMPDIR/db" "$pack" > "$out"
        diff - "$out" <<'EOF' || fail "unexpected rows"
        nix-agentic-tools/request-forgery-sinks client.js:3 request-forgery sink
        nix-agentic-tools/request-forgery-sinks client.js:4 request-forgery sink
        EOF
        # Reusing the merged file preserves the rows, but appending a foreign
        # --model-packs line beside ours must still be refused.
        mkdir "$TMPDIR/run"
        printf -- '--threads 1\n' > "$TMPDIR/consumer-config"
        XDG_RUNTIME_DIR="$TMPDIR/run" CODEQL_CONFIG_FILE="$TMPDIR/consumer-config" ${withModels}/bin/codeql resolve packs > /dev/null
        generated=("$TMPDIR"/run/codeql-config-*)
        CODEQL_CONFIG_FILE="''${generated[0]}" results ${withModels}/bin/codeql "$TMPDIR/db" "$pack" | diff - "$out" || fail "the merged config used as it is gives other rows"
        clash="$TMPDIR/generated-model-packs-config"
        { cat "''${generated[0]}"; printf -- '--model-packs %s\n' "$pack"; } > "$clash"
        refuses_config ${withModels}/bin/codeql "$clash" '--additional-packs or --model-packs'
      '';

    # Pack specs at eval, building no engine. A spec is plain data, so one spec
    # realized by two engines is two query packs, each compiled against its
    # engine; a model pack's content is only its language's, so it is one
    # derivation. codeql-bare, codeql-full without `language` and a spec in the
    # other kind's field throw. tryEval cannot see a message, so a probe
    # evaluates customization.nix over a stand-in engine, which nothing reads
    # before the refusals, and each refusal must name its cause.
    codeql-pack-specs = let
      drvOf = value: builtins.unsafeDiscardStringContext value.drvPath;
      named = codeql.mkQueryPack {
        inherit (queries) name src;
        language = "javascript";
      };
      namedModels = codeql.mkModelPack {
        inherit (models) name src;
        language = "javascript";
      };
      realizedBy = target: field: entry: builtins.head (target.customizePackage {${field} = [entry];}).packs.${field};
      # Force drvPath so these controls cover the actual exported engines'
      # validation, not just the stand-in's diagnostic path below.
      canCustomize = target: spec: builtins.seq (drvOf (target.customizePackage spec)) true;
      valid = {queries = [named];};
      specChecks = checkRows "codeql-pack-specs" {
        "bare engine accepts customization without packs but rejects a query spec" = rejectsChange (canCustomize packages.codeql-bare) {
          expected = true;
          invalid = {queries = [queries];};
          valid = {};
        };
        "full engine accepts a named language but rejects an inferred language" = rejectsChange (canCustomize packages.codeql-full) {
          inherit valid;
          expected = true;
          invalid = {queries = [queries];};
        };
        "javascript models field rejects a query spec in place of a model spec" = rejectsChange (canCustomize engine) {
          expected = true;
          invalid = {models = [queries];};
          valid = {models = [models];};
        };
        "mkQueryPack does not realize a derivation eagerly" = !lib.isDerivation queries;
        "model spec does not depend on the realizing engine" = drvOf (realizedBy engine "models" namedModels) == drvOf (realizedBy packages.codeql-full "models" namedModels);
        "package-set and flake-library query constructors do not diverge" = self.lib.ai.devTools.codeql.mkQueryPack {inherit (queries) name src;} == queries;
        "query spec is compiled separately for each realizing engine" = drvOf (realizedBy engine "queries" named) != drvOf (realizedBy packages.codeql-full "queries" named);
      };
      probe = pkgs.writeText "codeql-pack-specs.nix" ''
        {case}: let
          pkgs = import ${pkgs.path} {system = ${builtins.toJSON system};};
          inherit (pkgs) lib;
          specs = import ${../lib}/specs.nix {inherit lib;};
          customize = engineName: languages:
            import ${../lib}/customization.nix {
              engine = {
                outPath = "/nonexistent";
                pname = "codeql-''${engineName}";
                version = "0";
                meta = {
                  description = "stand-in";
                  license = lib.licenses.mit;
                  mainProgram = "codeql";
                  platforms = lib.platforms.all;
                };
              };
              inherit engineName languages pkgs;
            };
          query = specs.mkQueryPack {
            name = "me/q";
            src = ${./fixtures/queries};
          };
          cases = {
            bare = customize "bare" [] {queries = [query];};
            full = customize "full" ["javascript" "python"] {queries = [query];};
            kind = customize "javascript" ["javascript"] {models = [query];};
          };
        in
          builtins.seq cases.''${case}.drvPath true
      '';
    in
      assert specChecks;
        pkgs.runCommand "codeql-pack-specs" {nativeBuildInputs = [pkgs.nix];} ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          export HOME="$TMPDIR"
          fail() {
            echo "codeql-pack-specs: $*" >&2
            exit 1
          }
          # `refuses <case> <text>`: the probe fails and its error holds <text>.
          refuses() {
            if nix-instantiate --eval --strict --store dummy:// ${probe} --argstr case "$1" > /dev/null 2> "$TMPDIR/$1.err"; then
              fail "$1 was realized"
            fi
            grep -qF -- "$2" "$TMPDIR/$1.err" || fail "$1 failed without naming $2: $(cat "$TMPDIR/$1.err")"
            echo "$1: $2" >> "$out"
          }
          refuses bare "codeql-bare carries no CodeQL libraries"
          refuses full "codeql-full needs \`language\` on the spec"
          refuses kind "is a query pack spec; put it in \`queries\`"
        '';
  };
}
