# The pinned Kimchi release as one CodeQL database, and `runQueries`, which
# evaluates a query pack against it. Three layers, so a query edit rebuilds
# only its pack and its results, never the database: `source` and `database`
# move with the pins, the engine and the flake's nixpkgs (stdenv, bash, jq,
# coreutils, git), each `runQueries` result with its pack. `createDatabase`
# and `mkQueryRunner` are the same two steps as scripts, so a check can run
# the same pack over a fixture tree. See ../docs/kimchi-codeql.md for the
# source-root decision and the measurements.
#
# Every derivation name carries `codeql`, which the credentialed cachix steps'
# pushFilter drops, so none of them reaches the public cache.
{
  # The plain codeql-javascript engine. Query packs compile against it.
  engine,
  # Kimchi's GitHub release source, as fetched for extraction.
  kimchi,
  # The npm packages carried for extraction (pi and its MCP adapter).
  dependencies,
  pkgs,
  version,
}: let
  inherit (pkgs) lib;
  meta = {inherit (engine.meta) platforms;};
  # Dependencies land under node_modules, where Kimchi's imports resolve them.
  nodeModules = "kimchi/node_modules";

  # Kimchi's own TypeScript without tests and mocks, as extract.mjs reads it,
  # and each carried dependency under node_modules, with Kimchi's pnpm patches
  # applied the way the build's pnpm applies them. Kimchi's upstream
  # postinstall rewrite (scripts/patch-pi-ai-oauth.js, which replaces pi-ai's
  # dist/utils/oauth-page.js) is not applied, as extract.mjs does not
  # apply it. Source maps are dropped: the extractor does not read them, and
  # they are a third of pi's bytes.
  source =
    pkgs.runCommand "kimchi-codeql-source-${version}" {
      nativeBuildInputs = [pkgs.gitMinimal pkgs.jq];
      inherit meta;
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      mkdir -p "$out/kimchi" # bare-commands: ok (runCommand builder PATH)
      cp -R --no-preserve=mode ${kimchi}/src ${kimchi}/package.json ${kimchi}/tsconfig.json "$out/kimchi/" # bare-commands: ok (runCommand builder PATH)
      find "$out/kimchi/src" -name __mocks__ -type d -prune -exec rm -rf {} +
      find "$out/kimchi/src" -name '*.test.ts' -type f -delete
      for tree in ${lib.escapeShellArgs (map toString dependencies)}; do
        dest="$out/${nodeModules}/$(jq -er .name "$tree/package.json")"
        mkdir -p "$dest" # bare-commands: ok (runCommand builder PATH)
        cp -R --no-preserve=mode "$tree/dist" "$tree/package.json" "$dest/" # bare-commands: ok (runCommand builder PATH)
        # pi-mcp-adapter exports root TypeScript modules, which import its
        # other root sources; docs, examples and skills are not runtime code.
        find "$tree" -maxdepth 1 -type f \( -name '*.ts' -o -name '*.js' -o -name '*.cjs' -o -name '*.mjs' \) \
          -exec cp --no-preserve=mode {} "$dest/" \;
      done
      # Carried packages' patches must meet the exact version they name.
      # Missing pi packages fail; other uncarried packages may remain absent
      # only when their patch adds no environment reads. A patch is a diff,
      # not a program a parser can read, so that last check is a word match.
      jq -r '.pnpm.patchedDependencies | to_entries[] | "\(.key)\t\(.value)"' \
        ${kimchi}/package.json > patches
      while IFS=$'\t' read -r key file; do
        dest="$out/${nodeModules}/''${key%@*}"
        if [ ! -f "$dest/package.json" ]; then
          case "$key" in
            @earendil-works/pi-*) echo "kimchi-codeql-source: $key is patched but not carried" >&2; exit 1 ;;
          esac
          if grep -Eq '^\+.*\benv\b' ${kimchi}/"$file"; then
            echo "kimchi-codeql-source: $file adds a line naming env to a package this tree does not carry; carry the package so the environment query reads it" >&2
            exit 1
          fi
          continue
        fi
        carried="$(jq -er .version "$dest/package.json")"
        [ "$carried" = "''${key##*@}" ] || { echo "kimchi-codeql-source: $key is patched, but $carried is carried" >&2; exit 1; }
        # pnpm accepts missing EOF markers and unequal leading/trailing
        # context counts. GNU patch --fuzz=0 rejects those pi 1.3.0 hunks.
        # Match every context line with Git, allowing whitespace changes.
        git -C "$dest" apply --ignore-space-change ${kimchi}/"$file"
      done < patches
      find "$out" -name '*.map' -type f -delete
    '';

  # `kimchi-codeql-create-database <dir> [<tree>]` copies <tree>, by default
  # `source`, to <dir>/source and creates <dir>/db from it. The database
  # derivation and the codeql:kimchi-db devenv task both run it, so the two
  # hold the same database; a check runs it over a fixture tree laid out like
  # `source`, so the fixture is extracted the same way.
  #
  # The extractor skips node_modules unless an include names it, and skips a
  # file it judges minified unless told otherwise; pi's dist/bundle chunks
  # are. dist/bundle is pi's standalone CLI, which Kimchi never loads. It is
  # carried for the env reads of pi's bundled third-party dependencies at
  # pi's build-time versions, and it holds unpatched copies of patched pi-ai,
  # pi-tui and pi-coding-agent code, so a query scopes or labels its rows.
  createDatabase = pkgs.writeShellApplication {
    name = "kimchi-codeql-create-database";
    bashOptions = ["errexit" "errtrace" "functrace" "nounset" "pipefail"];
    runtimeInputs = [pkgs.coreutils];
    text = ''
      shopt -s inherit_errexit 2>/dev/null || :
      if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
        echo "usage: kimchi-codeql-create-database <dir> [<tree>]" >&2
        exit 2
      fi
      mkdir -p "$1" # bare-commands: ok (runtimeInputs PATH)
      rm -rf "$1/source" "$1/db" # bare-commands: ok (runtimeInputs PATH)
      cp -R --no-preserve=mode "''${2:-${source}}" "$1/source" # bare-commands: ok (runtimeInputs PATH)
      export CODEQL_EXTRACTOR_JAVASCRIPT_ALLOW_MINIFIED_FILES=true
      export LGTM_INDEX_FILTERS="include:${nodeModules}"
      exec ${engine}/bin/codeql database create "$1/db" \
        --language=javascript \
        --build-mode=none \
        --source-root="$1/source" \
        --threads="''${NIX_BUILD_CORES:-0}"
    '';
  };

  # `databaseOf name tree`: the database of `tree`, laid out as `source` is,
  # under $out/db, without its creation logs. A directory, not a bundle: a
  # query writes its cache into the database, so every consumer copies it
  # first, and copying the directory is faster than unpacking a bundle.
  # Input-addressed, so a check cache serves it while its inputs are
  # unchanged; it is not bit-reproducible.
  databaseOf = name: tree:
    pkgs.runCommand "kimchi-codeql-database-${name}" {inherit meta;} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      export HOME="$TMPDIR"
      ${lib.getExe createDatabase} "$TMPDIR/kimchi" ${tree}
      rm -rf "$TMPDIR/kimchi/db/log" # bare-commands: ok (runCommand builder PATH)
      mkdir -p "$out" # bare-commands: ok (runCommand builder PATH)
      mv "$TMPDIR/kimchi/db" "$out/db" # bare-commands: ok (runCommand builder PATH)
    '';
  database = databaseOf version source;

  # `mkQueryRunner { queries; models ? []; }`: a `kimchi-codeql-run-queries
  # <db> <out>` script that runs every query of `queries`, a mkQueryPack
  # result, against the writable database directory <db> with `models`
  # (mkModelPack results) through customizePackage. `<out>/<query>.json`
  # holds every result set of `<query>.ql`, decoded, its tuples sorted.
  # Select strings, relative paths and numbers: an entity or an absolute
  # location carries the build directory into the output.
  mkQueryRunner = {
    queries,
    models ? [],
  }: let
    customized = engine.customizePackage {
      inherit models;
      queries = [queries];
    };
    pack = queries.name;
  in
    assert lib.assertMsg (lib.isType "codeql-pack-spec" queries) "kimchi codeql.mkQueryRunner: `queries` must be a query pack";
      import ../../../lib/strict-shell-application.nix pkgs {
        name = "kimchi-codeql-run-queries";
        runtimeInputs = [customized pkgs.coreutils pkgs.findutils pkgs.jq];
        text = ''
          if [ "$#" -ne 2 ]; then
            echo "usage: kimchi-codeql-run-queries <db> <out>" >&2
            exit 2
          fi
          # Without --ram the evaluator caps its heap near 1800 MB on a 16 GB
          # runner, which global data flow outgrows.
          codeql database run-queries "$1" ${lib.escapeShellArg pack} \
            --ram=8192 \
            --threads="''${NIX_BUILD_CORES:-0}"
          results="$1/results/${pack}"
          [ -n "$(find "$results" -name '*.bqrs' -print -quit)" ] || { echo "kimchi-codeql-run-queries: ${pack} produced no results" >&2; exit 1; }
          mkdir -p "$2" # bare-commands: ok (runtimeInputs PATH)
          find "$results" -name '*.bqrs' -printf '%P\n' | while read -r bqrs; do
            json="$2/''${bqrs%.bqrs}.json"
            mkdir -p "$(dirname "$json")" # bare-commands: ok (runtimeInputs PATH)
            codeql bqrs decode --format=json "$results/$bqrs" | jq --sort-keys 'map_values(.tuples |= sort)' > "$json"
          done
        '';
      };

  # `runQueries { name; queries; models ? []; on ? database; }`: the runner
  # over a copy of `on`, a `databaseOf` result, as a derivation named for the
  # pack's purpose.
  runQueries = {
    name,
    queries,
    models ? [],
    on ? database,
  }:
    pkgs.runCommand "kimchi-codeql-${name}" {inherit meta;} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      export HOME="$TMPDIR"
      cp -R --no-preserve=mode ${on}/db "$TMPDIR/db" # bare-commands: ok (runCommand builder PATH)
      ${lib.getExe (mkQueryRunner {inherit models queries;})} "$TMPDIR/db" "$out"
    '';
in {
  inherit createDatabase database databaseOf engine mkQueryRunner runQueries;
}
