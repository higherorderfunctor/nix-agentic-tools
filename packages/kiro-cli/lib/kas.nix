# KAS is proprietary release data, extracted before the native package is built.
# Keep its name under the existing kiro-cli cache exclusion filter.
{
  pkgs,
  src,
  sourceRoot,
  version,
}: patches: let
  inherit (pkgs) lib;
  vu = import ./packaging.nix;
  # `patches` is the manifest `lib/mkKiro.nix` builds: `{}` when nothing is edited,
  # else `replace` (built-in tweak names) and/or `prompts` (consumer entries).
  selected = patches != {};
  prompts = patches.prompts or {};
  replace = patches.replace or [];
  promptsFile = pkgs.writeText "kiro-prompt-edits.json" (builtins.toJSON prompts);
in
  pkgs.stdenvNoCC.mkDerivation {
    pname = "kiro-cli-kas" + lib.optionalString selected "-patched";
    inherit src sourceRoot version;
    nativeBuildInputs =
      [pkgs.nodejs pkgs.python3]
      ++ lib.optional pkgs.stdenv.hostPlatform.isLinux pkgs.autoPatchelfHook;
    buildInputs = lib.optional pkgs.stdenv.hostPlatform.isLinux pkgs.stdenv.cc.cc.lib;
    dontConfigure = true;
    dontBuild = true;
    dontStrip = true;
    installPhase = ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      runHook preInstall
      chat=$(python3 ${vu.kiroLocateChatScript pkgs} .)
      python3 ${../extract/embedded-kas.py} "$chat" "$out" ${vu.kiroEmbeddedArgs pkgs pkgs.stdenv.hostPlatform.parsed.cpu.name}
      server="$out/node_modules/@kiro/agent/dist/server/acp-server.js"
      # Facts come from the ORIGINAL bytes: the patcher validates every edit against
      # them, then splices once. The original prompts ship under share/ whatever is selected.
      ${vu.kiroPromptFactsExtractScript pkgs} "$server" > "$TMPDIR/prompt-leaves.json"
      python3 ${./kiro-bundle-patch.py} "$server" "$TMPDIR/prompt-leaves.json" "$server" \
        --export-leaves "$out/share/kiro/vendorSteering" \
        ${lib.optionalString (prompts != {}) "--prompts ${promptsFile}"} \
        ${lib.concatMapStringsSep " " (name: "--replace ${lib.escapeShellArg name}") (lib.sort builtins.lessThan (lib.unique replace))}
      node --check "$server"
      runHook postInstall
    '';
    meta = {
      description = "KAS runtime embedded in the pinned Kiro CLI release (AWS-IPL)";
      homepage = "https://kiro.dev";
      license = lib.licenses.unfree;
      platforms = ["aarch64-darwin" "x86_64-linux"];
      sourceProvenance = [lib.sourceTypes.binaryNativeCode];
    };
  }
