# PROTOTYPE. CodeQL's per-language JavaScript bundle, and a runner that
# evaluates one table query over a source tree offline.
#
# Dev-only, never an overlay package and never in ciPackages: the bundle is
# unfree under the GitHub CodeQL Terms, which forbid sharing, publishing or
# distributing the CLI. Every credentialed cachix-action step filters its
# pname, ci-packages.py excludes it, and ci.yml asserts the cache does not
# serve it. A runner's `$out` holds only the decoded JSON, so no check output
# carries the CLI or a database in its closure. The Hestia check cache in this
# repository's private GitHub Actions cache deliberately holds the bundle as a
# build input: that is CI-internal storage, not distribution. The guards above
# target public publication only.
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
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
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
      mkdir -p "$out/bin" "$out/share" # bare-commands: ok (stdenv builder PATH)
      cp -R . "$out/share/codeql" # bare-commands: ok (stdenv builder PATH)
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

  # `runQuery { columns; jq; name; query; src; }`: a derivation whose `$out`
  # is `jq`'s output over the decoded result set of `query` (a file in the
  # query pack below), evaluated against a database of `src`. `columns` is
  # the number of selected columns: the decode sorts on all of them, because
  # an unsorted decode differs between otherwise identical databases.
  # Select only strings, relative paths and line numbers; an entity or an
  # absolute location would carry the store path into the result.
  runQuery = {
    columns,
    jq,
    name,
    query,
    src,
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
      cp -R --no-preserve=mode ${src} "$TMPDIR/source" # bare-commands: ok (runCommand builder PATH)
      cp -R --no-preserve=mode ${./queries} "$TMPDIR/queries" # bare-commands: ok (runCommand builder PATH)
      # An explicit language keeps the CLI from asking the GitHub API to
      # detect one; JavaScript supports only build mode none.
      codeql database create "$TMPDIR/db" \
        --language=javascript-typescript \
        --build-mode=none \
        --source-root="$TMPDIR/source" \
        --threads="$NIX_BUILD_CORES"
      # HOME is /homeless-shelter, so the compilation cache needs a home.
      # Without --ram the evaluator capped its heap at 1800 MB on a 16 GB CI
      # runner; global taint flow wants more.
      codeql query run \
        --database="$TMPDIR/db" \
        --common-caches="$TMPDIR/codeql" \
        --ram=8192 \
        --threads="$NIX_BUILD_CORES" \
        --output="$TMPDIR/result.bqrs" \
        "$TMPDIR/queries/${query}"
      # One result set decodes to {columns, tuples}, with no set-name key.
      codeql bqrs decode \
        --format=json \
        --result-set='#select' \
        --sort-key=${lib.concatMapStringsSep "," toString (lib.range 0 (columns - 1))} \
        --output="$TMPDIR/result.json" \
        "$TMPDIR/result.bqrs"
      jq --sort-keys ${lib.escapeShellArg jq} "$TMPDIR/result.json" > "$out"
      # Into the build log too, so a CI run shows the result without
      # anyone having to fetch the output.
      jq --compact-output . "$out"
    '';
  # `networkTargets { name; src; }`: every constant URL (a string with a
  # scheme) that taint-flows into the URL of a modeled client request in `src`,
  # as `{ hosts.<host> = [files]; otherTargets.<url> = [files]; }`, the files
  # being those of the requests. Taint means the constant influences the URL:
  # it may be any part of a concatenation or template, so its host is not
  # proven to be the request's. network-targets.jq does the projection, and
  # checks/extracted/codeql-projection.nix holds it to its cases.
  networkTargets = {
    name,
    src,
  }:
    runQuery {
      inherit name src;
      columns = 2;
      jq = builtins.readFile ./network-targets.jq;
      query = "NetworkTargets.ql";
    };
in {
  inherit bundle networkTargets;
}
