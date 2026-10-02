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

  rev = "85b0399bf214f24f5028d9cedecdd020f646c822";
  src = ourPkgs.fetchFromGitHub {
    owner = "github";
    repo = "github-mcp-server";
    inherit rev;
    hash = "sha256-MhLMbLe6fM1dd+acRxJW5ZXIuwxl8WYl9xZ2DUWZMec=";
  };

  # TRUNK-TRACKED, so the floor is a recipe literal rather than a sidecar key.
  # The rev-bump worker runs fixGoFloor after replacing rev + src hash and before
  # nix-update derives vendorHash, keeping the builder synchronized with go.mod.
  goFloor = "1.25.12";
  fixGoFloor = vu.mkGoFloorFix {
    attr = "github-mcp";
    pkgs = ourPkgs;
    pname = "github-mcp";
    recipeFile = repoPath ./package.nix;
  };
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
        inherit fixGoFloor goFloor;
        mcpName = "github-mcp";
      };
  })
