# PROTOTYPE. CodeQL's per-language JavaScript bundle, and a runner that
# evaluates one table query over a source tree offline.
#
# Dev-only, never an overlay package and never in ciPackages: the bundle is
# unfree under the GitHub CodeQL Terms, which forbid sharing, publishing or
# distributing the CLI. Every credentialed cachix-action step filters its
# pname, ci-packages.py excludes it, and ci.yml asserts the cache does not
# serve it. A runner's `$out` holds only the decoded JSON, so no check output
# carries the CLI or a database in its closure.
#
# The Terms allow automated database creation only for an OSI-licensed
# codebase hosted and maintained on GitHub.com. Point a runner at a
# fetchFromGitHub (or GitHub archive) source of such a codebase, never at an
# npm tarball.
{pkgs}: let
  inherit (pkgs) lib;
  version = "2.27.1";
  bundle = pkgs.stdenv.mkDerivation {
    pname = "codeql-bundle-javascript";
    inherit version;
    src = pkgs.fetchurl {
      # Per-language bundles carry no .checksum.txt; this is the release
      # API's `digest` for the asset.
      url = "https://github.com/github/codeql-action/releases/download/codeql-bundle-v${version}/codeql-bundle-javascript-linux64.tar.zst";
      hash = "sha256-jTAoGJnxUGM5E7CM9OrnVb5gfygtZDrUGK1jj0IQ6DM=";
    };
    nativeBuildInputs = [pkgs.autoPatchelfHook pkgs.zstd];
    buildInputs = [pkgs.stdenv.cc.cc.lib pkgs.zlib];
    # The bundled JRE's desktop and sound libraries; the headless CLI never
    # loads them. The 32-bit build-tracer libraries are skipped by
    # autoPatchelf's architecture check.
    autoPatchelfIgnoreMissingDeps = [
      "libX11.so.6"
      "libXext.so.6"
      "libXi.so.6"
      "libXrender.so.1"
      "libXtst.so.6"
      "libasound.so.2"
    ];
    unpackPhase = ''
      runHook preUnpack
      zstd -dc "$src" | tar -x
      runHook postUnpack
    '';
    sourceRoot = "codeql";
    dontConfigure = true;
    dontBuild = true;
    # Stripping the JRE's libraries and the tracer objects gains nothing and
    # risks breaking them.
    dontStrip = true;
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/bin" "$out/share"
      cp -R . "$out/share/codeql"
      # The launcher follows symlinks back to its distribution directory.
      ln -s "$out/share/codeql/codeql" "$out/bin/codeql"
      runHook postInstall
    '';
    meta = {
      description = "CodeQL CLI with the JavaScript/TypeScript extractor and query packs (dev-only, never published)";
      homepage = "https://github.com/github/codeql-action";
      license = lib.licenses.unfree;
      mainProgram = "codeql";
      platforms = ["x86_64-linux"];
      sourceProvenance = [lib.sourceTypes.binaryNativeCode lib.sourceTypes.binaryBytecode];
    };
  };

  # `runQuery { name; src; query; columns; jq; }`: a derivation whose `$out`
  # is `jq`'s output over the decoded result set of `query` (a file in the
  # query pack below), evaluated against a database of `src`. `columns` is
  # the number of selected columns: the decode sorts on all of them, because
  # an unsorted decode differs between otherwise identical databases.
  # Select only strings, relative paths and line numbers; an entity or an
  # absolute location would carry the store path into the result.
  runQuery = {
    name,
    src,
    query,
    columns,
    jq,
  }:
    pkgs.runCommand name {
      nativeBuildInputs = [bundle pkgs.jq];
      # TypeScript extraction starts Node.js.
      SEMMLE_TYPESCRIPT_NODE_RUNTIME = lib.getExe pkgs.nodejs;
      meta.platforms = bundle.meta.platforms;
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      # Writable copies: the database caches results under itself, and query
      # resolution may write a lock file beside the pack.
      cp -R --no-preserve=mode ${src} "$TMPDIR/source"
      cp -R --no-preserve=mode ${./queries} "$TMPDIR/queries"
      # An explicit language keeps the CLI from asking the GitHub API to
      # detect one; JavaScript supports only build mode none.
      codeql database create "$TMPDIR/db" \
        --language=javascript-typescript \
        --build-mode=none \
        --source-root="$TMPDIR/source" \
        --threads="$NIX_BUILD_CORES"
      # HOME is /homeless-shelter, so the compilation cache needs a home.
      codeql query run \
        --database="$TMPDIR/db" \
        --common-caches="$TMPDIR/codeql" \
        --threads="$NIX_BUILD_CORES" \
        --output="$TMPDIR/result.bqrs" \
        "$TMPDIR/queries/${query}"
      codeql bqrs decode \
        --format=json \
        --sort-key=${lib.concatMapStringsSep "," toString (lib.range 0 (columns - 1))} \
        --output="$TMPDIR/result.json" \
        "$TMPDIR/result.bqrs"
      jq --sort-keys ${lib.escapeShellArg jq} "$TMPDIR/result.json" > "$out"
    '';
  # `networkTargets { name; src; }`: every constant URL a modeled client
  # request in `src` reaches, as `{ hosts.<host> = [files]; otherTargets.<url>
  # = [files]; }`. A URL without a scheme (a relative path, a bare host) has
  # no host to key on and stays whole under otherTargets, so nothing the query
  # found is dropped. An empty result set fails: it means the query or the
  # extraction found nothing, not that the program makes no requests.
  networkTargets = {
    name,
    src,
  }:
    runQuery {
      inherit name src;
      query = "NetworkTargets.ql";
      columns = 2;
      jq = ''
        .["#select"].tuples
        | if length == 0 then error("NetworkTargets found no client request with a constant URL") else . end
        | map({url: .[0], file: .[1]}
          | .host = ((.url | capture("^[A-Za-z][A-Za-z0-9+.-]*://([^/?#@]*@)?(?<host>[^/?#:]+)") | .host | ascii_downcase) // null))
        | def files(key): group_by(key) | map({key: (.[0] | key), value: (map(.file) | unique)}) | from_entries;
          {
            hosts: (map(select(.host != null)) | files(.host)),
            otherTargets: (map(select(.host == null)) | files(.url))
          }
      '';
    };
in {
  inherit bundle networkTargets runQuery;
}
