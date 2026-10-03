# mcp-language-server — override nixpkgs to pin inline-sourced version.
#
# nixpkgs uses finalAttrs pattern with buildGoModule + proxyVendor.
# We override version + src + vendorHash; the fixed-point re-derives
# the rest.
{
  pkgs,
  packageLib,
  repoPath,
  ...
}: let
  vu = packageLib;

  rev = "e4395849a52e18555361abab60a060802c06bf50";
  src = pkgs.fetchFromGitHub {
    owner = "isaacphi";
    repo = "mcp-language-server";
    inherit rev;
    hash = "sha256-INyzT/8UyJfg1PW5+PqZkIy/MZrDYykql0rD2Sl97Gg=";
  };

  goFloor = "1.24.0";
  toolchain = vu.mkGoToolchain {
    floor = goFloor;
    inherit pkgs;
    pname = "mcp-language-server";
    recipeFile = repoPath ./package.nix;
  };
in
  # The toolchain is a BUILDER argument, so `.override` is the only seam
  # that reaches it; the attrs below still compose with `overrideAttrs`.
  (toolchain.overridePackage pkgs.mcp-language-server)
  .overrideAttrs (_finalAttrs: old: {
    # No version file in upstream Go source; use 0.0.0 placeholder
    version = vu.mkVersion {
      upstream = "0.0.0";
      inherit rev;
    };
    inherit src;
    vendorHash = "sha256-5YUI1IujtJJBfxsT9KZVVFVib1cK/Alk73y5tqxi6pQ=";
    installCheckPhase = vu.mkMcpSmokeTest {bin = "mcp-language-server";};

    # Merge, never replace: buildGoModule hangs `goModules` and
    # `overrideModAttrs` here. See the nix-standards fragment.
    passthru = (old.passthru or {}) // toolchain.passthru;
  })
