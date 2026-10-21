# The pinned Kimchi release as one CodeQL database, and `runQueries`, which
# evaluates a query pack against it. Three layers, so a query edit rebuilds
# only its pack and its results, never the database: `source` and `database`
# move only with the pins, each `runQueries` result with its pack. See
# ../docs/kimchi-codeql.md for the source-root decision and the measurements.
#
# Every derivation name carries `codeql`, which the credentialed cachix steps'
# pushFilter drops, so none of them reaches the public cache.
{
  # The plain codeql-javascript engine. Query packs compile against it.
  engine,
  # Kimchi's GitHub release source, as fetched for extraction.
  kimchi,
  # pi's npm packages, as fetched for extraction.
  pi,
  pkgs,
  version,
}: let
  inherit (pkgs) lib;
  meta = {inherit (engine.meta) platforms;};
  # The pi packages land here, where Kimchi's imports resolve them.
  scope = "kimchi/node_modules/@earendil-works";

  # Kimchi's own TypeScript without tests and mocks, as extract.mjs reads it,
  # and each pi package's dist under `scope`, with Kimchi's pnpm patches
  # applied the way the build's pnpm applies them. Source maps are dropped:
  # the extractor does not read them, and they are a third of pi's bytes.
  source =
    pkgs.runCommand "kimchi-codeql-source-${version}" {
      nativeBuildInputs = [pkgs.jq];
      inherit meta;
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      mkdir -p "$out/kimchi" # bare-commands: ok (runCommand builder PATH)
      cp -R --no-preserve=mode ${kimchi}/src ${kimchi}/package.json ${kimchi}/tsconfig.json "$out/kimchi/" # bare-commands: ok (runCommand builder PATH)
      find "$out/kimchi/src" -name __mocks__ -type d -prune -exec rm -rf {} +
      find "$out/kimchi/src" -name '*.test.ts' -type f -delete
      for tree in ${lib.escapeShellArgs (map toString pi)}; do
        dest="$out/kimchi/node_modules/$(jq -er .name "$tree/package.json")"
        mkdir -p "$dest" # bare-commands: ok (runCommand builder PATH)
        cp -R --no-preserve=mode "$tree/dist" "$tree/package.json" "$dest/" # bare-commands: ok (runCommand builder PATH)
      done
      # Every pi patch must meet the package at the version it names: a patch
      # for a package or version not carried here fails rather than leaving
      # the database without it.
      jq -r '.pnpm.patchedDependencies | to_entries[] | select(.key | startswith("@earendil-works/pi-")) | "\(.key)\t\(.value)"' \
        ${kimchi}/package.json > patches
      [ -s patches ] || { echo "kimchi-codeql-source: Kimchi patches no pi package" >&2; exit 1; }
      while IFS=$'\t' read -r key file; do
        dest="$out/kimchi/node_modules/''${key%@*}"
        [ -f "$dest/package.json" ] || { echo "kimchi-codeql-source: $key is patched but not carried" >&2; exit 1; }
        carried="$(jq -er .version "$dest/package.json")"
        [ "$carried" = "''${key##*@}" ] || { echo "kimchi-codeql-source: $key is patched, but $carried is carried" >&2; exit 1; }
        patch -d "$dest" -p1 --fuzz=0 --forward --batch --no-backup-if-mismatch --silent < ${kimchi}/"$file"
      done < patches
      find "$out" -name '*.map' -type f -delete
    '';

  # `kimchi-codeql-database <dir>` copies `source` to <dir>/source and creates
  # <dir>/db from it. The database derivation and the codeql:kimchi-db devenv
  # task both run it, so the two hold the same database.
  #
  # The extractor skips node_modules unless an include names it, and skips a
  # file it judges minified unless told otherwise; pi's dist/bundle chunks
  # are, and they carry the reads of pi's bundled dependencies.
  createDatabase = pkgs.writeShellApplication {
    name = "kimchi-codeql-database";
    bashOptions = ["errexit" "errtrace" "functrace" "nounset" "pipefail"];
    runtimeInputs = [pkgs.coreutils];
    text = ''
      shopt -s inherit_errexit 2>/dev/null || :
      if [ "$#" -ne 1 ]; then
        echo "usage: kimchi-codeql-database <dir>" >&2
        exit 2
      fi
      mkdir -p "$1" # bare-commands: ok (runtimeInputs PATH)
      rm -rf "$1/source" "$1/db" # bare-commands: ok (runtimeInputs PATH)
      cp -R --no-preserve=mode ${source} "$1/source" # bare-commands: ok (runtimeInputs PATH)
      export CODEQL_EXTRACTOR_JAVASCRIPT_ALLOW_MINIFIED_FILES=true
      export LGTM_INDEX_FILTERS="include:${scope}"
      exec ${engine}/bin/codeql database create "$1/db" \
        --language=javascript \
        --build-mode=none \
        --source-root="$1/source" \
        --threads="''${NIX_BUILD_CORES:-0}"
    '';
  };

  # The database directory under $out/db, without its creation logs. A
  # directory, not a bundle: a query writes its cache into the database, so
  # every consumer copies it first, and copying the directory is faster than
  # unpacking a bundle. Input-addressed, so a check cache serves it while the
  # pins are unchanged; it is not bit-reproducible.
  database = pkgs.runCommand "kimchi-codeql-database-${version}" {inherit meta;} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    export HOME="$TMPDIR"
    ${lib.getExe createDatabase} "$TMPDIR/kimchi"
    rm -rf "$TMPDIR/kimchi/db/log" # bare-commands: ok (runCommand builder PATH)
    mkdir -p "$out" # bare-commands: ok (runCommand builder PATH)
    mv "$TMPDIR/kimchi/db" "$out/db" # bare-commands: ok (runCommand builder PATH)
  '';

  # `runQueries { name; queries; models ? []; }`: every query of `queries`, a
  # mkQueryPack result, run against `database` with `models` (mkModelPack
  # results) through customizePackage. `$out/<query>.json` holds every result
  # set of `<query>.ql`, decoded, its tuples sorted. Select strings, relative
  # paths and numbers: an entity or an absolute location carries the build
  # directory into the output.
  runQueries = {
    name,
    queries,
    models ? [],
  }: let
    customized = engine.customizePackage {
      inherit models;
      queries = [queries];
    };
    pack = queries.codeqlPack.name or (throw "kimchi codeql.runQueries: `queries` must be a mkQueryPack result");
  in
    assert lib.assertMsg ((queries.codeqlPack.kind or null) == "query") "kimchi codeql.runQueries: `queries` must be a query pack";
      pkgs.runCommand "kimchi-codeql-${name}" {
        nativeBuildInputs = [customized pkgs.jq];
        inherit meta;
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        export HOME="$TMPDIR"
        cp -R --no-preserve=mode ${database}/db "$TMPDIR/db" # bare-commands: ok (runCommand builder PATH)
        # Without --ram the evaluator caps its heap near 1800 MB on a 16 GB
        # runner, which global data flow outgrows.
        codeql database run-queries "$TMPDIR/db" ${lib.escapeShellArg pack} \
          --ram=8192 \
          --threads="$NIX_BUILD_CORES"
        results="$TMPDIR/db/results/${pack}"
        [ -n "$(find "$results" -name '*.bqrs' -print -quit)" ] || { echo "kimchi-codeql-${name}: ${pack} produced no results" >&2; exit 1; }
        mkdir -p "$out" # bare-commands: ok (runCommand builder PATH)
        find "$results" -name '*.bqrs' -printf '%P\n' | while read -r bqrs; do
          json="$out/''${bqrs%.bqrs}.json"
          mkdir -p "$(dirname "$json")" # bare-commands: ok (runCommand builder PATH)
          codeql bqrs decode --format=json "$results/$bqrs" | jq --sort-keys 'map_values(.tuples |= sort)' > "$json"
        done
      '';
in {
  inherit createDatabase database engine runQueries source;
}
