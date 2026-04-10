# GitHub Copilot CLI — pre-built binary from GitHub releases.
# Platform-specific tarballs: copilot-{linux-x64,darwin-arm64}.tar.gz
#
# Unfree (proprietary). ensureUnfreeCheck in default.nix wraps the
# output so the consumer's allowUnfree config is respected.
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
    hash = nv.${system};
  };
in
  ourPkgs.github-copilot-cli.overrideAttrs (_: {
    inherit src;
    inherit (nv) version;
  })
