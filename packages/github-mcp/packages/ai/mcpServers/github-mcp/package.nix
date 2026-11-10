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

  rev = "6fbcd00b2034502ba3001a49dfaf93593aee7069";
  src = pkgs.fetchFromGitHub {
    owner = "github";
    repo = "github-mcp-server";
    inherit rev;
    hash = "sha256-lIZkV1sxHPZTSGZiZi2hogvaUr/VLQT052xuw/oxzaY=";
  };

  goFloor = "1.27.3";
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
    vendorHash = "sha256-2RfJhHB5dL8fHZY1gunVRAGGA3pOAA1YOeyi40Tfovc=";
    installCheckPhase = vu.mkMcpSmokeTest {bin = "github-mcp-server";};
    passthru =
      (old.passthru or {})
      // toolchain.passthru
      // {mcpName = "github-mcp";};
  })
