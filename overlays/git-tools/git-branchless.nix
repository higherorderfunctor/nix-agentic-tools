# Instantiate `ourPkgs` from `inputs.nixpkgs` so every build input
# (rust toolchain, makeRustPlatform, base derivation) routes through
# this repo's pinned nixpkgs instead of the consumer's. This is what
# gives the store path cache-hit parity against CI's standalone build
# — see dev/fragments/overlays/overlay-pattern.md
#
# Argument shape adapted from legacy 3-layer curried pattern during Milestone 6 port.
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
    overlays = [inputs.rust-overlay.overlays.default];
  };
  inherit (ourPkgs) fetchFromGitHub;

  vu = import ../version-utils.nix;

  # Pin to 1.88.0 — git-branchless v0.10.0 has esl01-indexedlog build
  # failure on Rust 1.89+ (arxanas/git-branchless#1585). Update this
  # when upstream fixes the issue or a new release ships.
  rust = ourPkgs.rust-bin.stable."1.88.0".default;
  rustPlatform = ourPkgs.makeRustPlatform {
    cargo = rust;
    rustc = rust;
  };

  rev = "f238c0993fea69700b56869b3ee9fd03178c6e32";
  src = fetchFromGitHub {
    owner = "arxanas";
    repo = "git-branchless";
    inherit rev;
    hash = "sha256-ar2168yI3OgNMwqrzilKK9QORKbe1QtHVe88JkS7EOs=";
  };
in
  ourPkgs.git-branchless.override (_: {
    rustPlatform.buildRustPackage = args:
      rustPlatform.buildRustPackage (finalAttrs: let
        a = (ourPkgs.lib.toFunction args) finalAttrs;
      in
        a
        // {
          version = vu.mkVersion {
            upstream = vu.readCargoVersion "${src}/git-branchless/Cargo.toml";
            inherit rev;
          };
          inherit src;
          cargoHash = "sha256-vLm/RuOc7K0YRvFvrA356OmcmLYzdpBjETsSCn+KyT4=";
          postPatch = null;
          # Strip versionCheckHook — binary reports Cargo.toml version
          # which won't match our computed version with +shortrev suffix.
          nativeInstallCheckInputs =
            builtins.filter
            (p: (p.pname or "") != "version-check-hook")
            (a.nativeInstallCheckInputs or []);
        });
  })
