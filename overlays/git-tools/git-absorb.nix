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

  rust = ourPkgs.rust-bin.stable.latest.default;
  rustPlatform = ourPkgs.makeRustPlatform {
    cargo = rust;
    rustc = rust;
  };
in
  ourPkgs.git-absorb.override (_: {
    rustPlatform.buildRustPackage = args:
      rustPlatform.buildRustPackage (finalAttrs: let
        a = (ourPkgs.lib.toFunction args) finalAttrs;
      in
        a
        // {
          inherit (nv) version src;
          inherit (nv) cargoHash;
        });
  })
