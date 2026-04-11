# Claude Code — pre-built binary from Anthropic's GPG-signed manifest.
#
# Per-platform binaries fetched from Google Cloud Storage. Version
# checked against manifest.json. nix-update manages version + hashes.
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
  inherit (ourPkgs) autoPatchelfHook fetchurl lib makeWrapper stdenv writeShellScript;

  version = "2.1.101";

  # Manifest base URL for version checks and binary downloads.
  manifestBase = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases";

  platformKey =
    {
      "x86_64-linux" = "linux-x64";
      "aarch64-darwin" = "darwin-arm64";
    }.${
      stdenv.hostPlatform.system
    };

  platformSrc = {
    "x86_64-linux" = fetchurl {
      url = "${manifestBase}/${version}/${platformKey}/claude";
      hash = "sha256-dLNyzz5KYVtLFowfQxM4p52OQPqBMFUzmKQ4+STYHGY=";
    };
    "aarch64-darwin" = fetchurl {
      url = "${manifestBase}/${version}/${platformKey}/claude";
      hash = "sha256-DE1Yv97jONpHNT6v2fDbd+x8SjDmxb6mKcU1+RzrpiQ=";
    };
  };
in
  stdenv.mkDerivation {
    pname = "claude-code";
    inherit version;
    src = platformSrc.${stdenv.hostPlatform.system};
    dontUnpack = true;
    dontBuild = true;
    nativeBuildInputs =
      [makeWrapper]
      ++ lib.optionals stdenv.hostPlatform.isLinux [autoPatchelfHook];
    buildInputs = lib.optionals stdenv.hostPlatform.isLinux [
      ourPkgs.glibc
    ];
    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      install -Dm755 $src $out/bin/claude
      runHook postInstall
    '';
    passthru.updateScript = writeShellScript "update-claude-code" ''
      set -eu
      version=$(${ourPkgs.curl}/bin/curl -s "${manifestBase}/latest")
      update-source-version claude-code "$version" --ignore-same-version
    '';
    meta = {
      mainProgram = "claude";
      license = lib.licenses.unfree;
      description = "Anthropic's Claude Code CLI";
    };
  }
