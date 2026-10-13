# KAS is proprietary release data, extracted before the native package is built.
# Keep its name under the existing kiro-cli cache exclusion filter.
{
  pkgs,
  src,
  sourceRoot,
  version,
}: {
  identity ? null,
  replace ? [],
}: let
  inherit (pkgs) lib;
  vu = import ./packaging.nix;
  selected = identity != null || replace != [];
in
  pkgs.stdenvNoCC.mkDerivation (finalAttrs: {
    pname = "kiro-cli-kas" + lib.optionalString selected "-patched";
    inherit src sourceRoot version;
    outputs = ["out" "corpus"];
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
      ${vu.kiroPromptsExtractScript pkgs} "$server" > "$corpus"
      defaults="$(dirname "$server")/prompt-defaults"
      python3 ${./kiro-bundle-patch.py} "$server" "$corpus" "$server" \
        --prompt-defaults "$defaults" \
        ${lib.optionalString (identity != null) "--identity-file ${lib.escapeShellArg (pkgs.writeText "kiro-cli-identity.txt" identity)}"} \
        ${lib.concatMapStringsSep " " (name: "--replace ${lib.escapeShellArg name}") (lib.sort builtins.lessThan (lib.unique replace))}
      ${vu.kiroPromptsExtractScript pkgs} "$server" > selected-corpus.json
      node ${../src/patch-prompt-files.mjs} "$server" "$defaults" ${pkgs.typescript_5}/lib/node_modules/typescript selected-corpus.json
      cp ${../src/additional-roots.mjs} "$(dirname "$server")/additional-roots.mjs" # bare-commands: ok — stdenv installPhase
      cp ${../src/prompt-files.mjs} "$(dirname "$server")/prompt-files.mjs" # bare-commands: ok — stdenv installPhase
      cp ${../src/session-settings.mjs} "$(dirname "$server")/session-settings.mjs" # bare-commands: ok — stdenv installPhase
      node --check "$server"
      runHook postInstall
    '';
    # Original release facts, before text or session hooks. No out -> corpus
    # reference, and no second installed pristine runtime or extraction build.
    passthru.promptCorpus = finalAttrs.finalPackage.corpus;
    meta = {
      description = "KAS runtime embedded in the pinned Kiro CLI release (AWS-IPL)";
      homepage = "https://kiro.dev";
      license = lib.licenses.unfree;
      platforms = ["aarch64-darwin" "x86_64-linux"];
      sourceProvenance = [lib.sourceTypes.binaryNativeCode];
    };
  })
