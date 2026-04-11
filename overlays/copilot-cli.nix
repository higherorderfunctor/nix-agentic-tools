# GitHub Copilot CLI — pre-built binary from GitHub releases.
# Per-platform inline sources with hashes.
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
  inherit (ourPkgs) fetchurl;
  inherit (ourPkgs.stdenv.hostPlatform) system;
  version = "1.0.22";
  platformSrc = {
    "x86_64-linux" = {
      inherit version;
      src = fetchurl {
        url = "https://github.com/github/copilot-cli/releases/download/v${version}/copilot-linux-x64.tar.gz";
        hash = "sha256-2h40sQXtHPpftSz0MQg98PVW078PLMyPmZ+wwAMxQIE=";
      };
    };
    "aarch64-darwin" = {
      inherit version;
      src = fetchurl {
        url = "https://github.com/github/copilot-cli/releases/download/v${version}/copilot-darwin-arm64.tar.gz";
        hash = "sha256-uIuUUmwxWe9yt/4Eh9h2OXVwb5+QfWeWe0XvXVIBpu4=";
      };
    };
  };
  nv = platformSrc.${system} or (throw "copilot-cli: unsupported system ${system}");
in
  ourPkgs.github-copilot-cli.overrideAttrs (_: {
    inherit (nv) src version;
  })
