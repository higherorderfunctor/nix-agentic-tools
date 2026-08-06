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
  final,
  ...
}: let
  # go-overlay is applied INSIDE this import so `go-bin` resolves against
  # our own pin; it is purely additive (`pkgs.go` is byte-identical with
  # and without it), so it moves no derivation.
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
    overlays = [inputs.go-overlay.overlays.default];
  };
  vu = import ../lib.nix;

  rev = "e4395849a52e18555361abab60a060802c06bf50";
  src = ourPkgs.fetchFromGitHub {
    owner = "isaacphi";
    repo = "mcp-language-server";
    inherit rev;
    hash = "sha256-INyzT/8UyJfg1PW5+PqZkIy/MZrDYykql0rD2Sl97Gg=";
  };

  # TRUNK-TRACKED — literal rather than a sidecar key, for the same
  # reason github-mcp.nix carries one: no sidecar, and `nix-update` owns
  # the rev bump, so there is no repo-owned script to hook a rewrite
  # into. `checks/go-floor-drift.nix` verifies it against this `src`.
  goFloor = "1.24.0";
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
    passthru = (old.passthru or {}) // {inherit goFloor;};
  })
