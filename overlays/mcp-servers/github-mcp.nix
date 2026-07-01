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

  rev = "225c47cda1d5f7fba3a90292933ade8d9a801c47";
  src = ourPkgs.fetchFromGitHub {
    owner = "github";
    repo = "github-mcp-server";
    inherit rev;
    hash = "sha256-YuFEtJTnkgTSsg2r/xE68pWnU4y/tP/bwyYoMSIy7tI=";
  };
in
  ourPkgs.github-mcp-server.overrideAttrs (_finalAttrs: old: {
    version = vu.mkVersion {
      upstream = "0.33.0";
      inherit rev;
    };
    inherit src;
    vendorHash = "sha256-MZhdZFYbn1k+Dh1gd9cuuuHfmtd1Fm6K0yku9rPNF54=";
    installCheckPhase = vu.mkMcpSmokeTest {bin = "github-mcp-server";};
    passthru = (old.passthru or {}) // {mcpName = "github-mcp";};
  })
