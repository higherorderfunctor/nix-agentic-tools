# Claude Code — pre-built binary from Anthropic's GPG-signed manifest.
# Per-platform sources in claude-code-sources.json, managed by updateScript.
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
  stdenv.mkDerivation (finalAttrs: {
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
    passthru = {
      updateScript = vu.mkUpdateScript {
        pname = "claude-code";
        versionCheck.cmd = "${ourPkgs.curl}/bin/curl -s ${manifestBase}/latest";
        platforms = {
          "x86_64-linux" = ver: "${manifestBase}/${ver}/linux-x64/claude";
          "aarch64-darwin" = ver: "${manifestBase}/${ver}/darwin-arm64/claude";
        };
        # Regenerate the committed sidecar from the freshly-bumped binary
        # in the SAME update/claude-code PR (no intra-PR drift). See
        # `vu.mkExtractRegen` for why the `nix fmt` pass is load-bearing.
        extraExtract = vu.mkExtractRegen {
          attr = "claude-code";
          dest = "overlays/claude-code-extracted.json";
          pkgs = ourPkgs;
        };
        pkgs = ourPkgs;
      };
      # THIS package's own binary -> committed-sidecar shape: the settings
      # schema comes from the binary's own emitter (unpacked module graph +
      # census), the model catalog and launch pins from anchored greps.
      # IFD-safe: consumed ONLY by `nix build` (drift check + update
      # script), NEVER readFile'd at eval. See overlays.md § IFD Patterns.
      #
      # `runCommand`, NOT `runCommandLocal`. runCommandLocal adds
      # `allowSubstitutes = false`, which bars this output from ever being
      # fetched from the binary cache — so every PR and every local `nix flake check`
      # re-derives it, and because the input is `finalAttrs.finalPackage`
      # that means realizing the ~390 MB claude binary locally to produce a
      # ~90 KB JSON. With `runCommand` the sidecar substitutes and the binary
      # is only fetched when it actually moved.
      #
      # `nodejs_24` and not `nodejs`: census.mjs drives `node:module`'s
      # `registerHooks`, which needs Node >= 22.15. Pinned so a nixpkgs
      # default bump cannot regress it.
      extracted =
        ourPkgs.runCommand "claude-code-extracted.json" {
          nativeBuildInputs = [ourPkgs.jq ourPkgs.nodejs_24 ourPkgs.python3];
        } (
          vu.mkClaudeExtract {
            assets = ./claude-code;
            bin = "${finalAttrs.finalPackage}/bin/claude";
            pkgs = ourPkgs;
            dest = "$out";
          }
        );
    };
    meta = {
      mainProgram = "claude";
      license = lib.licenses.unfree;
      description = "Anthropic's Claude Code CLI";
    };
  })
