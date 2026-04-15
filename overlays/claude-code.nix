# Claude Code — pre-built binary from Anthropic's GPG-signed manifest.
# Per-platform sources in claude-code-sources.json, managed by updateScript.
#
# This is the raw package. The HM module adds the buddy wrapper on
# top for users who configure buddy salt patching.
#
# IMPORTANT: The binary is a Bun single-exec with the application
# embedded via a trailer after the ELF data. autoPatchelfHook
# corrupts the trailer by rewriting ELF sections. We use manual
# patchelf --set-interpreter (header-only, safe) + makeWrapper for
# LD_LIBRARY_PATH (no binary modification).
#
# Unfree: wrapped by `ensureUnfreeCheck` in default.nix.
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
  inherit (ourPkgs) fetchurl lib makeWrapper stdenv;
  vu = import ./lib.nix;

  manifestBase = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases";

  sources = builtins.fromJSON (builtins.readFile ./claude-code-sources.json);
  platformSrc = sources.${stdenv.hostPlatform.system} or (throw "claude-code: unsupported system ${stdenv.hostPlatform.system}");
in
  stdenv.mkDerivation {
    pname = "claude-code";
    inherit (sources) version;
    src = fetchurl {inherit (platformSrc) url hash;};
    dontUnpack = true;
    dontBuild = true;
    # No autoPatchelfHook — it corrupts the Bun single-exec trailer.
    nativeBuildInputs = [makeWrapper];
    dontPatchELF = true;
    dontStrip = true;
    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      install -Dm755 $src $out/bin/.claude-unwrapped
      ${lib.optionalString stdenv.hostPlatform.isLinux ''
        # Patch only the ELF interpreter (header-only change, preserves
        # the Bun trailer). No --set-rpath: that adds sections which
        # shift the binary and corrupt the embedded application data.
        patchelf --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" \
          $out/bin/.claude-unwrapped
      ''}
      makeWrapper $out/bin/.claude-unwrapped $out/bin/claude \
        ${lib.optionalString stdenv.hostPlatform.isLinux ''--set LD_LIBRARY_PATH "${lib.makeLibraryPath [ourPkgs.glibc]}"''}
      runHook postInstall
    '';
    passthru.updateScript = vu.mkUpdateScript {
      pname = "claude-code";
      versionCheck.cmd = "${ourPkgs.curl}/bin/curl -s ${manifestBase}/latest";
      platforms = {
        "x86_64-linux" = ver: "${manifestBase}/${ver}/linux-x64/claude";
        "aarch64-darwin" = ver: "${manifestBase}/${ver}/darwin-arm64/claude";
      };
      pkgs = ourPkgs;
    };
    meta = {
      mainProgram = "claude";
      license = lib.licenses.unfree;
      description = "Anthropic's Claude Code CLI";
    };
  }
