# Claude Code — pre-built binary from Anthropic's GPG-signed manifest.
#
# Per-platform binaries fetched from Google Cloud Storage. Version
# checked against manifest.json. nix-update manages version + hashes.
#
# Buddy wrapper: if $XDG_STATE_HOME/claude-code-buddy/lib/cli.js
# exists, runs it via bun (for buddy salt patching). Otherwise
# runs the native binary directly.
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
  inherit (ourPkgs) autoPatchelfHook bun fetchurl lib makeWrapper stdenv writeShellScript;

  version = "2.1.101";

  # Manifest base URL for version checks and binary downloads.
  manifestBase = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases";

  platformKey = {
    "x86_64-linux" = "linux-x64";
    "aarch64-darwin" = "darwin-arm64";
  }.${stdenv.hostPlatform.system};

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

  buddyWrapper = writeShellScript "claude-buddy-wrapper" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :

    USER_LIB="''${XDG_STATE_HOME:-$HOME/.local/state}/claude-code-buddy/lib"

    if [ -f "$USER_LIB/cli.js" ]; then
      exec ${bun}/bin/bun run "$USER_LIB/cli.js" "$@"
    else
      exec @out@/bin/.claude-unwrapped "$@"
    fi
  '';
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
      install -Dm755 $src $out/bin/.claude-unwrapped
      substitute ${buddyWrapper} $out/bin/claude \
        --subst-var out
      chmod +x $out/bin/claude
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
