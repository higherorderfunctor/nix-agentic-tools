# Claude Code — pre-built binary from Anthropic's GPG-signed manifest.
# Per-platform sources in claude-code-sources.json, managed by updateScript.
#
# This is the raw package. The HM module adds the buddy wrapper on
# top for users who configure buddy salt patching.
#
# IMPORTANT: The binary is a Bun single-exec with the application
# embedded via a trailer after the ELF data.
#
# - autoPatchelfHook corrupts the trailer by rewriting ELF sections.
# - patchelf --set-rpath adds sections that shift the binary.
# - LD_LIBRARY_PATH poisons child processes (bash, python3, etc.)
#   because they inherit it and load the wrong glibc.
#
# We use only patchelf --set-interpreter (header-only, safe). The
# patched interpreter finds glibc via its own search path — no
# rpath or LD_LIBRARY_PATH needed. Verified with ldd.
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
  inherit (ourPkgs) fetchurl lib stdenv;
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
    dontPatchELF = true;
    dontStrip = true;
    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      install -Dm755 $src $out/bin/claude
      ${lib.optionalString stdenv.hostPlatform.isLinux ''
        # Patch only the ELF interpreter (header-only change, preserves
        # the Bun trailer). The patched interpreter finds glibc via its
        # own search path — no --set-rpath or LD_LIBRARY_PATH needed.
        patchelf --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" \
          $out/bin/claude
      ''}
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
