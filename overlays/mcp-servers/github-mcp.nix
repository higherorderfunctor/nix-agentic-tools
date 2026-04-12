# github-mcp — override nixpkgs to track main branch.
#
# nixpkgs uses finalAttrs pattern with buildGoModule. We override
# version + src + vendorHash; the fixed-point re-derives ldflags
# and the rest.
#
# Instantiates `ourPkgs` from `inputs.nixpkgs` for cache-hit parity
# (see dev/fragments/overlays/overlay-pattern.md).
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  vu = import ../lib.nix;

  rev = "c5ea8d32426c4cc55c75c305175fe2f6a39005ec";
  src = ourPkgs.fetchFromGitHub {
    owner = "github";
    repo = "github-mcp-server";
    inherit rev;
    hash = "sha256-FNSwZTz0RDP/BH2k66SBridiAZwAtuKsZaQgb/2jScA=";
  };
in
  ourPkgs.github-mcp-server.overrideAttrs (_finalAttrs: _old: {
    version = vu.mkVersion {
      upstream = "0.33.0";
      inherit rev;
    };
    inherit src;
    vendorHash = "sha256-q21hnMnWOzfg7BGDl4KM1I3v0wwS5sSxzLA++L6jO4s=";
  })
