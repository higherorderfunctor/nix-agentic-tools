# mcp-language-server — override nixpkgs to pin inline-sourced version.
#
# nixpkgs uses finalAttrs pattern with buildGoModule + proxyVendor.
# We override version + src + vendorHash; the fixed-point re-derives
# the rest.
#
# Instantiates `ourPkgs` from `inputs.nixpkgs` for cache-hit parity
# (see dev/fragments/overlays/overlay-pattern.md).
{
  inputs,
  pkgs,
  packageLib,
  repoPath,
  ...
}: let
  # go-overlay is applied INSIDE this import so `go-bin` resolves against
  # our own pin; it is purely additive (`pkgs.go` is byte-identical with
  # and without it), so it moves no derivation.
  ourPkgs = import inputs.nixpkgs {
    inherit (pkgs.stdenv.hostPlatform) system;
    overlays = [inputs.go-overlay.overlays.default];
  };
  vu = packageLib;

  rev = "e4395849a52e18555361abab60a060802c06bf50";
  src = ourPkgs.fetchFromGitHub {
    owner = "isaacphi";
    repo = "mcp-language-server";
    inherit rev;
    hash = "sha256-INyzT/8UyJfg1PW5+PqZkIy/MZrDYykql0rD2Sl97Gg=";
  };

  # TRUNK-TRACKED, so the floor is a recipe literal rather than a sidecar key.
  # The rev-bump worker runs fixGoFloor after replacing rev + src hash and before
  # nix-update derives vendorHash, keeping the builder synchronized with go.mod.
  goFloor = "1.24.0";
  fixGoFloor = vu.mkGoFloorFix {
    attr = "mcp-language-server";
    pkgs = ourPkgs;
    pname = "mcp-language-server";
    recipeFile = repoPath ./package.nix;
  };
in
  # The toolchain is a BUILDER argument, so `.override` is the only seam
  # that reaches it; the attrs below still compose with `overrideAttrs`.
  (ourPkgs.mcp-language-server.override {
    buildGoModule = vu.mkGoBuilder {
      floor = goFloor;
      pkgs = ourPkgs;
      pname = "mcp-language-server";
    };
  })
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
    passthru = (old.passthru or {}) // {inherit fixGoFloor goFloor;};
  })
