# `customizePackage` on the javascript engine, the one CI builds, with pack
# specs from `ai.devTools.codeql.mkQueryPack` and `mkModelPack`. Each check
# that builds creates a database of a fixture tree under ./fixtures and
# analyzes it; `$out` holds the result rows only. `codeql-pack-specs` only
# evaluates engines. See docs/customize.md.
{
  lib,
  pkgs,
  self,
  ...
}: let
  inherit (pkgs.stdenv.hostPlatform) system;
  packages = self.ciPackages.${system};
  engine = packages.codeql-javascript;
  # The namespace as a consumer reads it from the package set.
  codeql = pkgs.ai.devTools.codeql;
  queries = codeql.mkQueryPack {
    name = "nix-agentic-tools/fixture-queries";
    src = ./fixtures/queries;
  };
  sinkQueries = codeql.mkQueryPack {
    name = "nix-agentic-tools/fixture-sinks";
    src = ./fixtures/model-queries;
  };
  fetchModels = codeql.mkModelPack {
    name = "nix-agentic-tools/fixture-fetch-models";
    src = ./fixtures/fetch-models;
  };
  models = codeql.mkModelPack {
    name = "nix-agentic-tools/fixture-models";
    src = ./fixtures/models;
  };
  # Writes the mark and, with CODEQL_NESTED set, what that codeql resolves.
  marker = pkgs.writeShellApplication {
    name = "codeql-fixture-marker";
    bashOptions = ["errexit" "errtrace" "functrace" "nounset" "pipefail"];
    text = ''
      shopt -s inherit_errexit 2>/dev/null || :
      echo ran > "$CODEQL_FIXTURE_MARK"
      if [ -n "''${CODEQL_NESTED:-}" ]; then
        "$CODEQL_NESTED" resolve packs > "$CODEQL_FIXTURE_MARK.packs" 2>&1
      fi
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
    # A precompiled two-query pack resolves by name with no flag, and its
    # queries return the fixture rows, also with CODEQL_CONFIG_FILE=/dev/null
    # or a link to it.
    # A consumer's own config file, from CODEQL_CONFIG_FILE or HOME, still
    # applies beside it, also with no final newline, and the merged file
    # outlives the wrapper and is used as it is when given back; one that sets
    # --additional-packs is refused, indented too or beside a merged file's
    # lines, one whose comment names it is not. The TypeScript file is
    # extracted only with the engine's Node.
    codeql-custom-query-pack = let
      custom = engine.customizePackage {queries = [queries];};
    in
      check "codeql-custom-query-pack" ''
        plain=${engine}/bin/codeql
        codeql=${custom}/bin/codeql
        pack=nix-agentic-tools/fixture-queries
        [ -n "$(find ${builtins.head custom.packs.queries} -name '*.qlx' -print -quit)" ] || fail "the realized query pack has no precompiled .qlx"
        "$plain" resolve packs > "$TMPDIR/plain-packs" 2>&1
        ! grep -q " $pack@" "$TMPDIR/plain-packs" || fail "the plain engine resolves $pack"
        "$codeql" resolve packs > "$TMPDIR/packs" 2>&1
        grep -q " $pack@" "$TMPDIR/packs" || fail "the customized engine does not resolve $pack"
        CODEQL_CONFIG_FILE=/dev/null "$codeql" resolve packs > "$TMPDIR/devnull-packs" 2>&1 || fail "CODEQL_CONFIG_FILE=/dev/null: codeql failed: $(cat "$TMPDIR/devnull-packs")"
        grep -q " $pack@" "$TMPDIR/devnull-packs" || fail "CODEQL_CONFIG_FILE=/dev/null hides $pack"
        ln -s /dev/null "$TMPDIR/null-link"
        CODEQL_CONFIG_FILE="$TMPDIR/null-link" "$codeql" resolve packs > "$TMPDIR/null-link-packs" 2>&1 || fail "a CODEQL_CONFIG_FILE link to /dev/null: codeql failed: $(cat "$TMPDIR/null-link-packs")"
        grep -q " $pack@" "$TMPDIR/null-link-packs" || fail "a CODEQL_CONFIG_FILE link to /dev/null hides $pack"
        second=nix-agentic-tools/fixture-second
        mkdir -p "$TMPDIR/second" "$TMPDIR/home/.config/codeql"
        printf 'name: %s\nversion: 0.0.0\n' "$second" > "$TMPDIR/second/qlpack.yml"
        # `merged <label>` resolves packs and fails unless both ours and the
        # consumer's --search-path pack are listed.
        merged() {
          "$codeql" resolve packs > "$TMPDIR/$1-packs" 2>&1 || fail "$1: codeql failed: $(cat "$TMPDIR/$1-packs")"
          grep -q " $pack@" "$TMPDIR/$1-packs" || fail "$1: the consumer config hides $pack"
          grep -q " $second@" "$TMPDIR/$1-packs" || fail "$1: the consumer config's --search-path was lost"
        }
        printf -- '--search-path %s\n' "$TMPDIR/second" > "$TMPDIR/consumer-config"
        CODEQL_CONFIG_FILE="$TMPDIR/consumer-config" merged consumer
        printf -- '--search-path %s' "$TMPDIR/second" > "$TMPDIR/no-newline-config"
        CODEQL_CONFIG_FILE="$TMPDIR/no-newline-config" merged no-newline
        cp "$TMPDIR/consumer-config" "$TMPDIR/home/.config/codeql/config"
        HOME="$TMPDIR/home" merged home
        # The merged config outlives the wrapper under a name from its content:
        # two runs leave one file, the consumer's line before ours, and no
        # mktemp file behind.
        mkdir "$TMPDIR/run"
        for run in first second; do
          XDG_RUNTIME_DIR="$TMPDIR/run" CODEQL_CONFIG_FILE="$TMPDIR/consumer-config" merged "runtime-$run"
        done
        persisted=("$TMPDIR"/run/codeql-config-*)
        [ "''${#persisted[@]}" = 1 ] && [ -f "''${persisted[0]}" ] || fail "two runs left $(ls "$TMPDIR/run"), not one codeql-config-* file"
        theirsAt="$(grep -nm1 -- '^--search-path ' "''${persisted[0]}" | cut -d: -f1)"
        oursAt="$(grep -nm1 -- '^--additional-packs ' "''${persisted[0]}" | cut -d: -f1)"
        [ -n "$theirsAt" ] && [ -n "$oursAt" ] && [ "$theirsAt" -lt "$oursAt" ] || fail "the merged config does not hold the consumer's line before ours: $(cat "''${persisted[0]}")"
        [ -z "$(find "$TMPDIR/run" -name 'codeql-config.*')" ] || fail "the wrapper left a mktemp file: $(ls "$TMPDIR/run")"
        # Each run writes the file again rather than trusting what is there.
        echo JUNK > "''${persisted[0]}"
        XDG_RUNTIME_DIR="$TMPDIR/run" CODEQL_CONFIG_FILE="$TMPDIR/consumer-config" merged runtime-rewrite
        grep -q -- '^--additional-packs ' "''${persisted[0]}" && ! grep -qx JUNK "''${persisted[0]}" || fail "a run kept the stale ''${persisted[0]}: $(cat "''${persisted[0]}")"
        # A merged file is used as it is, and a line beside ours that sets an
        # option ours sets is still refused.
        CODEQL_CONFIG_FILE="''${persisted[0]}" merged generated
        { cat "''${persisted[0]}"; printf -- '--additional-packs %s\n' "$TMPDIR"; } > "$TMPDIR/generated-clash-config"
        status=0
        CODEQL_CONFIG_FILE="$TMPDIR/generated-clash-config" "$codeql" resolve packs 2> "$TMPDIR/generated-clash.err" || status=$?
        [ "$status" = 2 ] || fail "a merged config with a second --additional-packs line exited $status, not 2"
        grep -q customizePackage "$TMPDIR/generated-clash.err" || fail "the generated-clash message does not name customizePackage"
        # An XDG_RUNTIME_DIR that is not a directory falls back to TMPDIR.
        XDG_RUNTIME_DIR="$TMPDIR/missing" CODEQL_CONFIG_FILE="$TMPDIR/consumer-config" merged runtime-missing
        printf -- '# --additional-packs comes from customizePackage\n--search-path %s\n' "$TMPDIR/second" > "$TMPDIR/comment-config"
        CODEQL_CONFIG_FILE="$TMPDIR/comment-config" merged comment
        printf -- '--additional-packs %s\n' "$TMPDIR" > "$TMPDIR/clashing-config"
        if CODEQL_CONFIG_FILE="$TMPDIR/clashing-config" "$codeql" resolve packs 2> "$TMPDIR/clash.err"; then
          fail "a consumer --additional-packs line was accepted"
        fi
        grep -q customizePackage "$TMPDIR/clash.err" || fail "the clash message does not name customizePackage"
        printf -- '  --additional-packs %s\n' "$TMPDIR" > "$TMPDIR/indented-config"
        status=0
        CODEQL_CONFIG_FILE="$TMPDIR/indented-config" "$codeql" resolve packs 2> /dev/null || status=$?
        [ "$status" = 2 ] || fail "an indented consumer --additional-packs line exited $status, not 2"
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
    # cannot find the program. That program runs the customized codeql again,
    # which still resolves the pack, with and without a consumer config file.
    codeql-extra-packages = let
      custom = engine.customizePackage {
        extraPackages = [marker];
        queries = [queries];
      };
    in
      check "codeql-extra-packages" ''
        pack=nix-agentic-tools/fixture-queries
        export CODEQL_FIXTURE_MARK="$TMPDIR/mark" CODEQL_NESTED=${custom}/bin/codeql
        if database ${engine}/bin/codeql plain ${./fixtures/project} --command=codeql-fixture-marker 2> /dev/null; then
          fail "the plain engine ran codeql-fixture-marker"
        fi
        [ ! -e "$CODEQL_FIXTURE_MARK" ] || fail "the plain engine wrote the mark"
        database ${custom}/bin/codeql db ${./fixtures/project} --command=codeql-fixture-marker
        grep -qx ran "$CODEQL_FIXTURE_MARK" || fail "codeql-fixture-marker did not run"
        grep -q " $pack@" "$CODEQL_FIXTURE_MARK.packs" || fail "a nested codeql does not resolve $pack"
        rm "$CODEQL_FIXTURE_MARK" "$CODEQL_FIXTURE_MARK.packs"
        printf -- '--threads 1\n' > "$TMPDIR/consumer-config"
        CODEQL_CONFIG_FILE="$TMPDIR/consumer-config" database ${custom}/bin/codeql consumer ${./fixtures/project} --command=codeql-fixture-marker
        grep -qx ran "$CODEQL_FIXTURE_MARK" || fail "codeql-fixture-marker did not run beside a consumer config"
        grep -q " $pack@" "$CODEQL_FIXTURE_MARK.packs" || fail "a nested codeql beside a consumer config does not resolve $pack"
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
        status=0
        CODEQL_CONFIG_FILE="$TMPDIR/clashing-config" ${withModels}/bin/codeql resolve packs 2> "$TMPDIR/clash.err" || status=$?
        [ "$status" = 2 ] || fail "a consumer --model-packs line exited $status, not 2"
        grep -q customizePackage "$TMPDIR/clash.err" || fail "the clash message does not name customizePackage"
        results ${withModels}/bin/codeql "$TMPDIR/db" "$pack" > "$out"
        diff - "$out" <<'EOF' || fail "unexpected rows"
        nix-agentic-tools/request-forgery-sinks client.js:3 request-forgery sink
        nix-agentic-tools/request-forgery-sinks client.js:4 request-forgery sink
        EOF
        # The merged file a consumer config yields gives the same rows used as
        # it is, and refuses a line beside ours that sets either option.
        mkdir "$TMPDIR/run"
        printf -- '--threads 1\n' > "$TMPDIR/consumer-config"
        XDG_RUNTIME_DIR="$TMPDIR/run" CODEQL_CONFIG_FILE="$TMPDIR/consumer-config" ${withModels}/bin/codeql resolve packs > /dev/null
        generated=("$TMPDIR"/run/codeql-config-*)
        CODEQL_CONFIG_FILE="''${generated[0]}" results ${withModels}/bin/codeql "$TMPDIR/db" "$pack" | diff - "$out" || fail "the merged config used as it is gives other rows"
        for option in "--model-packs $pack" "--additional-packs $TMPDIR"; do
          { cat "''${generated[0]}"; printf '%s\n' "$option"; } > "$TMPDIR/generated-clash-config"
          status=0
          CODEQL_CONFIG_FILE="$TMPDIR/generated-clash-config" ${withModels}/bin/codeql resolve packs 2> /dev/null || status=$?
          [ "$status" = 2 ] || fail "a merged config with a consumer ''${option%% *} line exited $status, not 2"
        done
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
        name = "nix-agentic-tools/fixture-queries";
        src = ./fixtures/queries;
        language = "javascript";
      };
      namedModels = codeql.mkModelPack {
        name = "nix-agentic-tools/fixture-models";
        src = ./fixtures/models;
        language = "javascript";
      };
      realizedBy = target: field: entry: builtins.head (target.customizePackage {${field} = [entry];}).packs.${field};
      throws = target: field: entry: !(builtins.tryEval (drvOf (target.customizePackage {${field} = [entry];}))).success;
      failures =
        lib.optional (lib.isDerivation queries) "mkQueryPack returned a derivation"
        ++ lib.optional (self.lib.ai.devTools.codeql.mkQueryPack {inherit (queries) name src;} != queries)
        "lib.ai.devTools.codeql.mkQueryPack gives another spec than the package set's"
        ++ lib.optional (drvOf (realizedBy engine "queries" named) == drvOf (realizedBy packages.codeql-full "queries" named))
        "one query spec realized by codeql-javascript and codeql-full is one derivation"
        ++ lib.optional (drvOf (realizedBy engine "models" namedModels) != drvOf (realizedBy packages.codeql-full "models" namedModels))
        "one model spec realized by codeql-javascript and codeql-full is two derivations"
        ++ lib.optional (!throws packages.codeql-bare "queries" queries) "codeql-bare realized a query spec"
        ++ lib.optional (!throws packages.codeql-full "queries" queries) "codeql-full realized a query spec with no language"
        ++ lib.optional (throws packages.codeql-full "queries" named) "codeql-full refused a query spec with a language"
        ++ lib.optional (!throws engine "models" queries) "a query spec in `models` was taken";
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
          model = specs.mkModelPack {
            name = "me/m";
            src = ${./fixtures/models};
            language = "javascript";
          };
          cases = {
            bare = customize "bare" [] {queries = [query];};
            control = customize "full" ["javascript" "python"] {models = [model];};
            full = customize "full" ["javascript" "python"] {queries = [query];};
            kind = customize "javascript" ["javascript"] {models = [query];};
          };
        in
          builtins.seq cases.''${case}.drvPath true
      '';
    in
      assert lib.assertMsg (failures == []) "codeql-pack-specs:\n${lib.concatStringsSep "\n" failures}";
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
          nix-instantiate --eval --strict --store dummy:// ${probe} --argstr case control > /dev/null 2> "$TMPDIR/control.err" || fail "the control did not evaluate: $(cat "$TMPDIR/control.err")"
          refuses bare "codeql-bare carries no CodeQL libraries"
          refuses full "codeql-full needs \`language\` on the spec"
          refuses kind "is a query pack spec; put it in \`queries\`"
        '';
  };
}
