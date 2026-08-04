# GitHub Copilot CLI — standalone derivation against per-platform SEA tarball.
#
# Why standalone (not overrideAttrs): upstream nixpkgs commit e171111c
# (2026-05-21) rewrote `github-copilot-cli` from the per-platform SEA
# tarball (`copilot-<platform>.tar.gz`, flat layout, `sourceRoot = "."`,
# bash wrapper) to a universal Node tarball (`github-copilot-<ver>.tgz`,
# `package/` prefix, `sourceRoot = "package"`, node wrapper with
# `nodejs cacert glib libsecret`). The new shape is incompatible with
# the SEA src we fetch via `copilot-cli-sources.json` — overriding
# `sourceRoot`, `installPhase`, `postInstall`, and `buildInputs` would
# replace ~every interesting attr upstream sets, so override semantics
# stop carrying useful weight. We keep the SEA artifact for closure
# size (~20 MB vs hundreds of MB for the universal node tarball).
#
# Upstream-state detection is a non-blocking annotation step in
# `.github/workflows/update.yml` ("Detect upstream copilot-cli SEA
# restoration"). It surfaces in the Update job's annotation panel when
# upstream nixos-unstable HEAD changes mechanism away from the
# universal-node layout we forked against — same UX as the held-back-PR
# warnings, no eval-time tripwires here.
#
# Unfree (proprietary). ensureUnfreeCheck in default.nix wraps the
# output so the consumer's allowUnfree config is respected.
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
  inherit (ourPkgs) fetchurl lib makeWrapper autoPatchelfHook stdenv;
  inherit (ourPkgs.stdenv.hostPlatform) system;
  vu = import ./lib.nix;

  sources = builtins.fromJSON (builtins.readFile ./copilot-cli-sources.json);
  platformSrc = sources.${system} or (throw "copilot-cli: unsupported system ${system}");
in
  ourPkgs.stdenv.mkDerivation {
    pname = "copilot-cli";
    inherit (sources) version;
    src = fetchurl {inherit (platformSrc) url hash;};

    sourceRoot = ".";
    dontStrip = true;

    nativeBuildInputs =
      [makeWrapper]
      ++ lib.optionals stdenv.hostPlatform.isLinux [autoPatchelfHook];

    buildInputs = lib.optionals stdenv.hostPlatform.isLinux [
      stdenv.cc.cc.lib
    ];

    # The SEA tarball bundles its own runtime; autoPatchelf would
    # otherwise chase deps that don't matter for a single-exec binary.
    autoPatchelfIgnoreMissingDeps = true;

    installPhase = ''
      runHook preInstall
      install -Dm755 copilot $out/libexec/copilot
      runHook postInstall
    '';

    postInstall = ''
      makeWrapper $out/libexec/copilot $out/bin/copilot \
        --add-flags "--no-auto-update"
    '';

    passthru = {
      updateScript = vu.mkUpdateScript {
        pname = "copilot-cli";
        versionCheck.cmd = vu.ghLatestVersionCmd {
          pkgs = ourPkgs;
          repo = "github/copilot-cli";
        };
        platforms = {
          "x86_64-linux" = ver: "https://github.com/github/copilot-cli/releases/download/v${ver}/copilot-linux-x64.tar.gz";
          "aarch64-darwin" = ver: "https://github.com/github/copilot-cli/releases/download/v${ver}/copilot-darwin-arm64.tar.gz";
        };
        pkgs = ourPkgs;
      };
    };

    meta = {
      description = "GitHub Copilot CLI";
      homepage = "https://github.com/github/copilot-cli";
      license = lib.licenses.unfree;
      platforms = builtins.attrNames (builtins.removeAttrs sources ["version"]);
      mainProgram = "copilot";
    };
  }
