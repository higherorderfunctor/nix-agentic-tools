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

  rev = "7edc2dd123a8923db389de8772170663cb2d8e17";
  src = pkgs.fetchFromGitHub {
    owner = "github";
    repo = "github-mcp-server";
    inherit rev;
    hash = "sha256-0GWNFBvfCjg1B1H3y7/yxRz9EToKhcSjWPHERqeYluA=";
  };

  goFloor = "1.27.4";
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
    vendorHash = "sha256-xe11l2K2Zg1PmXEbnnPlIVHcOZJ0ucOpjq5ygJnxQUU=";
    installCheckPhase = vu.mkMcpSmokeTest {bin = "github-mcp-server";};
    passthru =
      (old.passthru or {})
      // toolchain.passthru
      // {mcpName = "github-mcp";};
  })
