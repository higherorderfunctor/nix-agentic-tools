# Claude Code — pre-built binary from Anthropic's GPG-signed manifest.
# Per-platform sources in claude-code-sources.json, managed by updateScript.
#
# This is the raw package. The HM module adds the buddy wrapper on
# top for users who configure buddy salt patching.
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
  inherit (ourPkgs) autoPatchelfHook fetchurl lib stdenv;
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
    nativeBuildInputs =
      lib.optionals stdenv.hostPlatform.isLinux [autoPatchelfHook];
    buildInputs = lib.optionals stdenv.hostPlatform.isLinux [
      ourPkgs.glibc
    ];
    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      install -Dm755 $src $out/bin/claude
      runHook postInstall
    '';
    passthru.updateScript = vu.mkUpdateScript {
      pname = "claude-code";
      versionCheck.cmd = "${ourPkgs.curl}/bin/curl -s ${manifestBase}/latest";
      platforms = {
        "x86_64-linux" = ver: "${manifestBase}/${ver}/linux-x64/claude";
        "aarch64-darwin" = ver: "${manifestBase}/${ver}/darwin-arm64/claude";
      };
      sourcesFile = "overlays/claude-code-sources.json";
      pkgs = ourPkgs;
    };
    meta = {
      mainProgram = "claude";
      license = lib.licenses.unfree;
      description = "Anthropic's Claude Code CLI";
    };
  }
