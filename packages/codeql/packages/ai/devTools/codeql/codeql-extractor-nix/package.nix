{
  packageLib,
  pkgs,
  repoPath,
}: let
  inherit (pkgs) lib;
  sources = builtins.fromJSON (builtins.readFile ../../../../../extractor-sources.json);
  librarySource = pkgs.fetchurl {inherit (sources.source) hash url;};
in
  pkgs.stdenv.mkDerivation (finalAttrs: {
    pname = "codeql-extractor-nix";
    inherit (sources) version;
    src = pkgs.fetchurl {inherit (sources.x86_64-linux) hash url;};
    nativeBuildInputs = [pkgs.autoPatchelfHook];
    buildInputs = [pkgs.stdenv.cc.cc.lib];
    dontBuild = true;
    dontConfigure = true;
    installPhase = ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      runHook preInstall
      mkdir -p "$out/extractor" "$out/ql"
      cp -R . "$out/extractor"
      tar xf ${librarySource} --strip-components=2 --wildcards -C "$out/ql" '*/ql/lib'
      # The release binary and QL library must use the same generated schema.
      cp "$out/extractor/nix.dbscheme" "$out/extractor/nix.dbscheme.stats" "$out/ql/lib/"
      printf '%s\n' '{"provide":["extractor/codeql-extractor.yml","ql/*/qlpack.yml"]}' > "$out/.codeqlmanifest.json"
      runHook postInstall
    '';
    passthru = {
      codeql = import ../../../../../lib/nix.nix {
        engine = pkgs.ai.devTools.codeql.codeql-javascript;
        extractor = finalAttrs.finalPackage;
        inherit pkgs;
      };
      codeqlLibraries.nix = "jamiemagee/nix-all";
      updateScript = packageLib.mkUpdateScript {
        inherit pkgs;
        pname = "codeql-extractor-nix";
        sourcesFile = repoPath ../../../../../extractor-sources.json;
        versionCheck.cmd = packageLib.ghLatestVersionCmd {
          inherit pkgs;
          repo = "JamieMagee/codeql-nix";
        };
        platforms = {
          source = version: "https://api.github.com/repos/JamieMagee/codeql-nix/tarball/v${version}";
          x86_64-linux = version: "https://github.com/JamieMagee/codeql-nix/releases/download/v${version}/codeql-extractor-nix-v${version}-linux64.tar.gz";
        };
      };
    };
    meta = {
      description = "Nix CodeQL extractor and QL library";
      homepage = "https://github.com/JamieMagee/codeql-nix";
      license = lib.licenses.mit;
      platforms = ["x86_64-linux"];
      sourceProvenance = [lib.sourceTypes.binaryNativeCode];
    };
  })
