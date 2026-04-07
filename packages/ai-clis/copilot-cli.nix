# GitHub Copilot CLI — pre-built binary from GitHub releases.
# Platform-specific tarballs: copilot-{linux-x64,darwin-arm64}.tar.gz
#
# Instantiates `ourPkgs` from `inputs.nixpkgs` so the base derivation
# (github-copilot-cli) and every build input (fetchurl) route through
# this repo's pinned nixpkgs instead of the consumer's. This is what
# gives the store path cache-hit parity against CI's standalone build
# — see .claude/rules/overlays.md and
# dev/notes/overlay-cache-hit-parity-fix.md.
{
  inputs,
  final,
  nv,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
  platformMap = {
    "aarch64-darwin" = "darwin-arm64";
    "x86_64-linux" = "linux-x64";
  };
  inherit (ourPkgs.stdenv.hostPlatform) system;
  suffix =
    platformMap.${system}
    or (throw "copilot-cli: unsupported system ${system}");
  src = ourPkgs.fetchurl {
    url = "https://github.com/github/copilot-cli/releases/download/v${nv.version}/copilot-${suffix}.tar.gz";
    hash =
      nv.${system}
      or (throw "copilot-cli: no hash for ${system}");
  };
in
  ourPkgs.github-copilot-cli.overrideAttrs (_: {
    inherit src;
    inherit (nv) version;
  })
