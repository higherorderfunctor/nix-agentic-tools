# github-mcp — override nixpkgs to track main branch.
#
# nixpkgs uses finalAttrs pattern with buildGoModule. We override
# version + src + vendorHash; the fixed-point re-derives ldflags
# and the rest.
{
  pkgs,
  packageLib,
  repoPath,
  ...
}: let
  vu = packageLib;

  rev = "eb47a99ddb866ca2b8a162920e6bda9521f33ebb";
  src = pkgs.fetchFromGitHub {
    owner = "github";
    repo = "github-mcp-server";
    inherit rev;
    hash = "sha256-A2h7fa+ab4d1BA1aa80fPqBhUbOF2jEDGAugRn9Y79o=";
  };

  goFloor = "1.26.8";
  toolchain = vu.mkGoToolchain {
    floor = goFloor;
    inherit pkgs;
    pname = "github-mcp";
    recipeFile = repoPath ./package.nix;
  };
in
  # The toolchain is a BUILDER argument, so `.override` is the only seam
  # that reaches it; the attrs below still compose with `overrideAttrs`.
  (toolchain.overridePackage pkgs.github-mcp-server)
  .overrideAttrs (_finalAttrs: old: {
    version = vu.mkVersion {
      upstream = "0.33.0";
      inherit rev;
    };
    inherit src;
    vendorHash = "sha256-kyQH4kOV93RGuY7gCD2YVCVt4403Zwqyb/wzW/1awXM=";
    installCheckPhase = vu.mkMcpSmokeTest {bin = "github-mcp-server";};
    passthru =
      (old.passthru or {})
      // toolchain.passthru
      // {mcpName = "github-mcp";};
  })
