# ChatGPT Codex CLI — standalone derivation against per-platform release
# tarballs.
#
# openai/codex ships the Rust CLI as per-platform `.tar.gz` archives on
# GitHub Releases, tagged `rust-v<version>` (the repo also cuts unrelated
# tags, hence `tagPrefix = "rust-v"` on the version check). Each archive
# holds ONE flat file — the target-triple-named binary, e.g.
# `codex-x86_64-unknown-linux-musl` — with no wrapper directory, so
# `sourceRoot = "."` and the install renames it to `$out/bin/codex`.
#
# Standalone (not overrideAttrs): there is no nixpkgs base package to
# inherit from, and the artifact is a self-contained binary. The Linux
# build is `static-pie linked` against musl, so unlike claude-code /
# kimchi it needs neither autoPatchelfHook nor an interpreter patch.
#
# Free (Apache-2.0). ensureUnfreeCheck in default.nix passes free packages
# through unwrapped.
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
  inherit (ourPkgs) fetchurl lib;
  inherit (ourPkgs.stdenv.hostPlatform) system;
  vu = import ./lib.nix;

  sources = builtins.fromJSON (builtins.readFile ./chatgpt-codex-sources.json);
  platformSrc = sources.${system} or (throw "chatgpt-codex: unsupported system ${system}");
in
  ourPkgs.stdenv.mkDerivation (finalAttrs: {
    pname = "chatgpt-codex";
    inherit (sources) version;
    src = fetchurl {inherit (platformSrc) url hash;};

    sourceRoot = ".";
    dontStrip = true;

    # The archive unpacks to a single `codex-<target-triple>` file; the
    # glob keeps this platform-agnostic so a new platform key needs no
    # install-phase edit.
    installPhase = ''
      runHook preInstall
      install -Dm755 codex-* $out/bin/codex
      runHook postInstall
    '';

    # Smoke test: a static binary either execs or it does not, so an
    # honest `--version` is a complete check that the install produced a
    # runnable `$out/bin/codex`.
    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck
      $out/bin/codex --version
      runHook postInstallCheck
    '';

    passthru = {
      updateScript = vu.mkUpdateScript {
        pname = "chatgpt-codex";
        versionCheck.cmd = vu.ghLatestVersionCmd {
          pkgs = ourPkgs;
          repo = "openai/codex";
          tagPrefix = "rust-v";
        };
        platforms = {
          "x86_64-linux" = ver: "https://github.com/openai/codex/releases/download/rust-v${ver}/codex-x86_64-unknown-linux-musl.tar.gz";
          "aarch64-darwin" = ver: "https://github.com/openai/codex/releases/download/rust-v${ver}/codex-aarch64-apple-darwin.tar.gz";
        };
        extraExtract = ''
          echo "chatgpt-codex: regenerating overlays/chatgpt-codex-extracted.json"
          extracted=$(${ourPkgs.nix}/bin/nix build --no-link --print-out-paths \
            ".#chatgpt-codex.passthru.extracted")
          ${ourPkgs.coreutils}/bin/cp "$extracted" overlays/chatgpt-codex-extracted.json
          ${ourPkgs.coreutils}/bin/chmod 644 overlays/chatgpt-codex-extracted.json
          ${ourPkgs.nix}/bin/nix fmt -- overlays/chatgpt-codex-extracted.json
          echo "chatgpt-codex: wrote overlays/chatgpt-codex-extracted.json"
        '';
        pkgs = ourPkgs;
      };
      extracted = ourPkgs.runCommandLocal "chatgpt-codex-extracted.json" {} (
        vu.mkCodexExtract {
          bin = "${finalAttrs.finalPackage}/bin/codex";
          pkgs = ourPkgs;
          inherit (sources) version;
          dest = "$out";
        }
      );
    };

    meta = {
      description = "OpenAI Codex CLI — coding agent that runs locally in your terminal";
      homepage = "https://github.com/openai/codex";
      license = lib.licenses.asl20;
      platforms = builtins.attrNames (builtins.removeAttrs sources ["version"]);
      mainProgram = "codex";
    };
  })
