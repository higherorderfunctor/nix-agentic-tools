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

  rev = "c3dedbece0bf3834829f638a245fb3c51cd98d0b";
  src = ourPkgs.fetchFromGitHub {
    owner = "github";
    repo = "github-mcp-server";
    inherit rev;
    hash = "sha256-y6QGF2g9FhDxtWR//kaI5Xt2o+MwaNWCf2t0t61/vww=";
  };
in
  ourPkgs.github-mcp-server.overrideAttrs (_finalAttrs: old: {
    version = vu.mkVersion {
      upstream = "0.33.0";
      inherit rev;
    };
    inherit src;
    vendorHash = "sha256-fVNMtCpodsr1Z9E21osHb+e63ZQqFKYwi4fz4OsTJe0=";
    installCheckPhase = vu.mkMcpSmokeTest {bin = "github-mcp-server";};
    passthru = (old.passthru or {}) // {mcpName = "github-mcp";};
  })
