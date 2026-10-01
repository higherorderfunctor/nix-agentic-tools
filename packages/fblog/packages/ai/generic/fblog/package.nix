# fblog: nixpkgs build recipe with release source and Cargo vendor pins.
# nix-update refreshes both hashes through the owner's update target.
{pkgs, ...}: let
  version = "4.17.0";
  src = pkgs.fetchFromGitHub {
    owner = "brocode";
    repo = "fblog";
    tag = "v${version}";
    hash = "sha256-SDOYW9CpC7E62nVnZL04Kx9ckVEZyvcMolJCfKDqdMk=";
  };
in
  pkgs.fblog.overrideAttrs (finalAttrs: _: {
    inherit src version;
    cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
      # pname and version name the output, so a stale hash cannot reuse the
      # previous release's cached vendor set after a bump.
      inherit (finalAttrs) pname version src;
      hash = "sha256-Pn8HsBz+5OHz4jF6xmORLQSLYClTHpaJXWiS5sPyV2w=";
    };
  })
