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
{
  pkgs,
  packageLib,
  repoPath,
  ...
}: let
  inherit (pkgs) fetchurl lib stdenv;
  vu = packageLib // import ../../../lib/packaging.nix;

  manifestBase = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases";

  sources = builtins.fromJSON (builtins.readFile ../../../sources.json);
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
    passthru = {
      updateScript = vu.mkUpdateScript {
        sourcesFile = repoPath ../../../sources.json;

        pname = "claude-code";
        versionCheck.cmd = "${pkgs.curl}/bin/curl -s ${manifestBase}/latest";
        platforms = {
          "x86_64-linux" = ver: "${manifestBase}/${ver}/linux-x64/claude";
          "aarch64-darwin" = ver: "${manifestBase}/${ver}/darwin-arm64/claude";
        };
        # Regenerate both committed raws from the freshly-bumped binaries
        # in the SAME update/claude-code PR (no intra-PR drift). The drift
        # check's regenerate command includes the load-bearing `nix fmt` pass.
        extraExtract = (import ../../../../../lib/extracted {inherit pkgs;}).regenCommand {name = "claude-code";};
        inherit pkgs;
      };
      # Each pinned platform's binary -> committed-raw shape: the settings
      # schema comes from the binary's own emitter (unpacked module graph +
      # census), the model catalog and launch pins from content-located AST reads.
      # IFD-safe: consumed ONLY by `nix build` (drift check + update
      # script), NEVER readFile'd at eval. See overlays.md § IFD Patterns.
      #
      # `runCommand`, NOT `runCommandLocal`. runCommandLocal adds
      # `allowSubstitutes = false`, which bars this output from ever being
      # fetched from the binary cache — so every PR and every local `nix flake check`
      # re-derives it, fetching the ~390 MB claude binary locally to produce
      # a ~90 KB JSON. With `runCommand` the raw substitutes and the binary
      # is only fetched when it actually moved. Extraction reads the fetched
      # bytes without executing them, so both platforms build on any host and
      # need no Linux interpreter patch.
      #
      # `nodejs_24` and not `nodejs`: census.mjs drives `node:module`'s
      # `registerHooks`, which needs Node >= 22.15. Pinned so a nixpkgs
      # default bump cannot regress it.
      extractedFor = lib.genAttrs (builtins.attrNames (builtins.removeAttrs sources ["version"])) (system:
        pkgs.runCommand "claude-code-${system}-extracted.json" {
          nativeBuildInputs = [pkgs.nodejs_24 pkgs.python3];
        } (vu.mkClaudeExtract {
          assets = ../../../extract;
          bin = fetchurl {inherit (sources.${system}) url hash;};
          inherit pkgs;
          dest = "$out";
        }));
    };
    meta = {
      mainProgram = "claude";
      license = lib.licenses.unfree;
      description = "Anthropic's Claude Code CLI";
    };
  }
