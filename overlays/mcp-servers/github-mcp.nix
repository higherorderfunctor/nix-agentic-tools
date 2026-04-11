# github-mcp — override nixpkgs to pin inline-sourced version.
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
in
  ourPkgs.github-mcp-server.overrideAttrs (finalAttrs: _old: {
    version = "0.33.0";
    src = ourPkgs.fetchFromGitHub {
      owner = "github";
      repo = "github-mcp-server";
      rev = "v${finalAttrs.version}";
      hash = "sha256-FNSwZTz0RDP/BH2k66SBridiAZwAtuKsZaQgb/2jScA=";
    };
    vendorHash = "sha256-q21hnMnWOzfg7BGDl4KM1I3v0wwS5sSxzLA++L6jO4s=";
  })
