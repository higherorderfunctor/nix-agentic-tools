# `mkEngine { engine; }`: one CodeQL engine derivation, `codeql-<engine>`,
# from its entry in ../sources.json. Every engine is the same CLI release
# unpacked, patched and installed the same way; only the asset differs. See
# ../docs/codeql.md for what each engine holds.
#
# Unfree under the GitHub CodeQL Terms, which forbid sharing, publishing or
# distributing the CLI. So no engine may reach the public Cachix cache: every
# credentialed cachix-action step filters `codeql`, ci-packages.py excludes
# every engine from the package shards, and ci.yml's `test` job asserts that
# no engine path answers from the cache. The Hestia check cache in this
# repository's private GitHub Actions cache deliberately holds an engine a
# check builds: that is CI-internal storage, not distribution. The guards
# target public publication only.
#
# The Terms allow automated database creation only for an OSI-licensed
# codebase hosted and maintained on GitHub.com.
{
  engine,
  packageLib,
  pkgs,
  repoPath,
}: let
  inherit (pkgs) lib;
  sources = builtins.fromJSON (builtins.readFile ../sources.json);
  source = sources.${engine};

  # Bundles are tagged `codeql-bundle-v<version>` on codeql-action, whose own
  # `v4.x` releases interleave with them, so `releases/latest` names the wrong
  # thing. The newest tag with the bundle prefix is the release.
  bundleRepo = "github/codeql-action";
  bundleTagPrefix = "codeql-bundle-v";
  assetUrl = name: version:
    if name == "bare"
    then "https://github.com/github/codeql-cli-binaries/releases/download/v${version}/codeql-linux64.zip"
    else "https://github.com/${bundleRepo}/releases/download/${bundleTagPrefix}${version}/codeql-bundle${lib.optionalString (name != "full") "-${name}"}-linux64.tar.zst";
  engines = builtins.attrNames (builtins.removeAttrs sources ["version"]);
  zip = lib.hasSuffix ".zip" source.url;
in
  pkgs.stdenv.mkDerivation {
    pname = "codeql-${engine}";
    inherit (sources) version;
    src = pkgs.fetchurl {inherit (source) hash url;};
    nativeBuildInputs = [
      pkgs.autoPatchelfHook
      (
        if zip
        then pkgs.unzip
        else pkgs.zstd
      )
    ];
    buildInputs = [pkgs.stdenv.cc.cc.lib pkgs.zlib];
    # Libraries the headless CLI never loads: the bundled JREs' desktop, font
    # and sound support, and the .NET runtime's LTTng trace provider. Measured
    # over every x86-64 ELF in the 2.27.3 full bundle and bare zip; all other
    # needs are glibc, libstdc++, libgcc_s, zlib or the bundle's own
    # libraries. autoPatchelf's architecture check skips the 32-bit build
    # tracer libraries.
    autoPatchelfIgnoreMissingDeps = [
      "libX11.so.6"
      "libXext.so.6"
      "libXi.so.6"
      "libXrender.so.1"
      "libXtst.so.6"
      "libasound.so.2"
      "libfreetype.so.6"
      "liblttng-ust.so.0"
    ];
    unpackPhase = ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      runHook preUnpack
      ${
        if zip
        then ''unzip -q "$src"''
        else ''zstd -dc "$src" | tar -x''
      }
      runHook postUnpack
    '';
    sourceRoot = "codeql";
    dontConfigure = true;
    dontBuild = true;
    # Stripping the JREs' libraries and the tracer objects gains nothing and
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
    # Every engine carries the same script, which bumps every asset from one
    # tag; the `codeql-full` update target runs it.
    passthru.updateScript = packageLib.mkUpdateScript {
      inherit pkgs;
      # Keyed by engine rather than by platform: each entry is one asset.
      platforms = lib.genAttrs engines assetUrl;
      pname = "codeql";
      sourcesFile = repoPath ../sources.json;
      versionCheck.cmd = "${pkgs.gitMinimal}/bin/git ls-remote --tags --refs https://github.com/${bundleRepo} 'refs/tags/${bundleTagPrefix}*' | ${pkgs.gnused}/bin/sed -n 's|.*refs/tags/${bundleTagPrefix}\\([0-9][0-9]*\\.[0-9][0-9]*\\.[0-9][0-9]*\\)$|\\1|p' | ${pkgs.coreutils}/bin/sort -V | ${pkgs.coreutils}/bin/tail -n 1";
    };
    meta = {
      description =
        if engine == "bare"
        then "CodeQL CLI with every extractor and no query packs"
        else if engine == "full"
        then "CodeQL CLI bundle with every extractor and query pack"
        else "CodeQL CLI bundle with the ${engine} extractor and query packs";
      homepage = "https://github.com/github/codeql-action";
      license = lib.licenses.unfree;
      mainProgram = "codeql";
      platforms = ["x86_64-linux"];
      sourceProvenance = [lib.sourceTypes.binaryBytecode lib.sourceTypes.binaryNativeCode];
    };
  }
