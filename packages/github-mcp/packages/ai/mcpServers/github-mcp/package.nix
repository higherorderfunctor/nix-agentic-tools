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
  pkgs,
  packageLib,
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

  rev = "c71961c7fc314adf6c7855a4c4a348adba0243db";
  src = ourPkgs.fetchFromGitHub {
    owner = "github";
    repo = "github-mcp-server";
    inherit rev;
    hash = "sha256-rJnujI7JIZg5mhNhppDC4k7d2Qnnhp/il6mLVBmcrfQ=";
  };

  # TRUNK-TRACKED, so the floor is a LITERAL here rather than a sidecar
  # key — this package has no sidecar, and it is bumped by `nix-update`
  # (a `git` target in the owner registry.nix), not by a repo-owned
  # update script there would be anywhere to hook a rewrite into.
  #
  # Hand-written but NOT hand-trusted: `checks/packaging/go-floor-drift.nix` reads
  # `passthru.goFloor` back, compares it against this exact `src`'s
  # go.mod, and fails naming the value to write. A rev bump that raises
  # the floor turns that check red instead of silently building against
  # whatever toolchain happens to be in scope.
  goFloor = "1.25.12";
in
  # The toolchain is a BUILDER argument, so `.override` is the only seam
  # that reaches it; the attrs below still compose with `overrideAttrs`.
  (ourPkgs.github-mcp-server.override {
    buildGoModule = vu.mkGoBuilder {
      floor = goFloor;
      pkgs = ourPkgs;
      pname = "github-mcp";
    };
  })
  .overrideAttrs (_finalAttrs: old: {
    version = vu.mkVersion {
      upstream = "0.33.0";
      inherit rev;
    };
    inherit src;
    vendorHash = "sha256-dqn9W2gOb3ZCfppzfSczDO2bvpwsGyPe4I/h6y3JL9A=";
    installCheckPhase = vu.mkMcpSmokeTest {bin = "github-mcp-server";};
    passthru =
      (old.passthru or {})
      // {
        inherit goFloor;
        mcpName = "github-mcp";
      };
  })
