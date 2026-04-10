# GitHub Copilot CLI — pre-built binary from GitHub releases.
# Per-platform nvfetcher entries: copilot-cli-linux-x64, copilot-cli-darwin-arm64.
#
# Unfree (proprietary). ensureUnfreeCheck in default.nix wraps the
# output so the consumer's allowUnfree config is respected.
{
  inputs,
  final,
  nv-linux-x64,
  nv-darwin-arm64,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
  inherit (ourPkgs.stdenv.hostPlatform) system;
  platformSrc = {
    "x86_64-linux" = nv-linux-x64;
    "aarch64-darwin" = nv-darwin-arm64;
  };
  nv = platformSrc.${system} or (throw "copilot-cli: unsupported system ${system}");
in
  ourPkgs.github-copilot-cli.overrideAttrs (_: {
    inherit (nv) src version;
  })
