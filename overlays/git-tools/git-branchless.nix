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
  nv,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
    overlays = [inputs.rust-overlay.overlays.default];
  };

  # Pin to 1.88.0 — git-branchless v0.10.0 has esl01-indexedlog build
  # failure on Rust 1.89+ (arxanas/git-branchless#1585). Update this
  # when upstream fixes the issue or a new release ships.
  rust = ourPkgs.rust-bin.stable."1.88.0".default;
  rustPlatform = ourPkgs.makeRustPlatform {
    cargo = rust;
    rustc = rust;
  };
in
  ourPkgs.git-branchless.override (_: {
    rustPlatform.buildRustPackage = args:
      rustPlatform.buildRustPackage (finalAttrs: let
        a = (ourPkgs.lib.toFunction args) finalAttrs;
      in
        a
        // {
          # Strip "v" prefix — nvfetcher gives "v0.10.0" from the tag
          # but the binary prints "0.10.0" in --version output.
          version = ourPkgs.lib.removePrefix "v" nv.version;
          inherit (nv) src;
          inherit (nv) cargoHash;
          postPatch = null;
        });
  })
