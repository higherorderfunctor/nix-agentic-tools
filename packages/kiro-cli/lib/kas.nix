# KAS is proprietary release data, extracted before the native package is built.
# Keep its name under the existing kiro-cli cache exclusion filter.
{
  pkgs,
  src,
  sourceRoot,
  version,
}: {replace ? []}: let
  inherit (pkgs) lib;
  vu = import ./packaging.nix;
  selected = replace != [];
in
  pkgs.stdenvNoCC.mkDerivation (finalAttrs: {
    pname = "kiro-cli-kas" + lib.optionalString selected "-patched";
    inherit src sourceRoot version;
    nativeBuildInputs =
      [pkgs.nodejs pkgs.python3]
      ++ lib.optional pkgs.stdenv.hostPlatform.isLinux pkgs.autoPatchelfHook
      ++ lib.optional pkgs.stdenv.hostPlatform.isDarwin pkgs.undmg;
    buildInputs = lib.optional pkgs.stdenv.hostPlatform.isLinux pkgs.stdenv.cc.cc.lib;
    dontConfigure = true;
    dontBuild = true;
    dontStrip = true;
    installPhase = ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      runHook preInstall
      chat=$(python3 ${vu.kiroLocateChatScript pkgs} .)
      python3 ${../extract/embedded-kas.py} "$chat" "$out" \
        --architecture ${lib.escapeShellArg pkgs.stdenv.hostPlatform.parsed.cpu.name} \
        --zstd-library ${lib.getLib pkgs.zstd}/lib/libzstd${pkgs.stdenv.hostPlatform.extensions.sharedLibrary} \
        --zstd ${pkgs.zstd}/bin/zstd
      server="$out/node_modules/@kiro/agent/dist/server/acp-server.js"
      ${lib.optionalString selected ''
        ${vu.kiroPromptsExtractScript pkgs} "$server" > prompt-corpus.json
        python3 ${./kiro-bundle-patch.py} "$server" prompt-corpus.json "$server" \
          ${lib.concatMapStringsSep " " (name: "--replace ${lib.escapeShellArg name}") (lib.sort builtins.lessThan (lib.unique replace))}
      ''}
      node --check "$server"
      runHook postInstall
    '';
    # Explicit inspection output: proprietary text stays outside the runtime
    # closure. Selected builds use their own temporary corpus, never this one.
    passthru.promptCorpus = pkgs.runCommand "kiro-cli-prompt-corpus-${version}" {inherit (finalAttrs) meta;} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${vu.kiroPromptsExtractScript pkgs} ${finalAttrs.finalPackage}/node_modules/@kiro/agent/dist/server/acp-server.js > "$out"
    '';
    meta = {
      description = "KAS runtime embedded in the pinned Kiro CLI release (AWS-IPL)";
      homepage = "https://kiro.dev";
      license = lib.licenses.unfree;
      platforms = ["aarch64-darwin" "x86_64-linux"];
      sourceProvenance = [lib.sourceTypes.binaryNativeCode];
    };
  })
