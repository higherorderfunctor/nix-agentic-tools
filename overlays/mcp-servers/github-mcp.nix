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

  rev = "62266f804b1e24b5c22f158c4c79b1db4950967c";
  src = ourPkgs.fetchFromGitHub {
    owner = "github";
    repo = "github-mcp-server";
    inherit rev;
    hash = "sha256-+351ua42EMz0tRxsbrGkARiE8aXMobTym3Yzh1rp8To=";
  };
in
  ourPkgs.github-mcp-server.overrideAttrs (_finalAttrs: _old: {
    version = vu.mkVersion {
      upstream = "0.33.0";
      inherit rev;
    };
    inherit src;
    vendorHash = "sha256-q21hnMnWOzfg7BGDl4KM1I3v0wwS5sSxzLA++L6jO4s=";
    installCheckPhase = vu.mkMcpSmokeTest {bin = "github-mcp-server";};
  })
