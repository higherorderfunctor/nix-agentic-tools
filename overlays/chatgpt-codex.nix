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
# The release publishes EIGHT separate binaries; we ship two. `codex` is the
# CLI. `codex-code-mode-host` is the Code Mode execution host, and Codex
# resolves it as a SIBLING of its own executable — so it must land in this
# derivation's `bin/`, not merely somewhere on PATH. Without it, Codex 0.147.0
# cannot run tool calls at all: it reports `failed to spawn code-mode host
# .../bin/codex-code-mode-host: No such file or directory` and every command
# fails closed. Both assets are pinned in lockstep by the update pipeline via
# `extraAssets` (see overlays/lib.nix) precisely so a bump can never move one
# without the other.
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
  # Absent only if the pipeline has not yet regenerated the sidecar with the
  # nested asset. Throw rather than silently ship a Codex that cannot execute
  # anything — a missing host is not a degraded mode, it is a dead tool loop.
  codeModeHostSrc =
    platformSrc.codeModeHost
    or (throw "chatgpt-codex: ${system} sidecar has no codeModeHost entry — re-run the update script to repin both release assets");
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
      # Unpacked AFTER the glob above, which would otherwise match both the
      # CLI and the host and hand `install` two sources for one destination.
      tar xzf ${fetchurl {inherit (codeModeHostSrc) url hash;}}
      install -Dm755 codex-code-mode-host-* $out/bin/codex-code-mode-host
      runHook postInstall
    '';

    # Smoke test: a static binary either execs or it does not, so an
    # honest `--version` is a complete check that the install produced a
    # runnable `$out/bin/codex`.
    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck
      $out/bin/codex --version
      # Existence + exec bit only. The host is a long-lived server that takes
      # no `--version`, so running it would hang the build; what actually
      # broke was the file not being there.
      test -x $out/bin/codex-code-mode-host
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
        # Pinned in LOCKSTEP with the CLI above — same release tag, same
        # regeneration. Hardcoding this URL in the overlay instead would
        # survive a bump untouched and pair a new CLI with an old host.
        extraAssets.codeModeHost = {
          "x86_64-linux" = ver: "https://github.com/openai/codex/releases/download/rust-v${ver}/codex-code-mode-host-x86_64-unknown-linux-musl.tar.gz";
          "aarch64-darwin" = ver: "https://github.com/openai/codex/releases/download/rust-v${ver}/codex-code-mode-host-aarch64-apple-darwin.tar.gz";
        };
        # Regenerate the committed sidecar from the freshly-bumped binary
        # in the SAME update/chatgpt-codex PR (no intra-PR drift).
        extraExtract = vu.mkExtractRegen {
          attr = "chatgpt-codex";
          dest = "overlays/chatgpt-codex-extracted.json";
          pkgs = ourPkgs;
        };
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
