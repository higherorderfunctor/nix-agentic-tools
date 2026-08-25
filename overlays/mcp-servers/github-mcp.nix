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
  # go-overlay is applied INSIDE this import so `go-bin` resolves against
  # our own pin; it is purely additive (`pkgs.go` is byte-identical with
  # and without it), so it moves no derivation.
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
    overlays = [inputs.go-overlay.overlays.default];
  };
  vu = import ../lib.nix;

  rev = "884c791d000c6ad27bbd76b3d0e3307e3988d0b3";
  src = ourPkgs.fetchFromGitHub {
    owner = "github";
    repo = "github-mcp-server";
    inherit rev;
    hash = "sha256-PjkF0ebfLWotjOaAYFvR17UNZT05Lv0iBT3+7Xijmhc=";
  };

  # TRUNK-TRACKED, so the floor is a LITERAL here rather than a sidecar
  # key — this package has no sidecar, and it is bumped by `nix-update`
  # (a `git` target in config/update-targets.nix), not by a repo-owned
  # update script there would be anywhere to hook a rewrite into.
  #
  # Hand-written but NOT hand-trusted: `checks/go-floor-drift.nix` reads
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
    vendorHash = "sha256-tNAC2tSmfTuT4OZmq7vrG2j5njJaL1NyN+/IjYegp60=";
    installCheckPhase = vu.mkMcpSmokeTest {bin = "github-mcp-server";};
    passthru =
      (old.passthru or {})
      // {
        inherit goFloor;
        mcpName = "github-mcp";
      };
  })
