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
          version = "unstable-2026-02-13";
          src = fetchFromGitHub {
            owner = "tummychow";
            repo = "git-absorb";
            rev = "debdcd28d9db2ac6b36205bda307b6693a6a91e7";
            hash = "sha256-jAR+Vq6SZZXkseOxZVJSjsQOStIip8ThiaLroaJcIfc=";
          };
          cargoHash = "sha256-8uCXk5bXn/x4QXbGOROGlWYMSqIv+/7dBGZKbYkLfF4=";
        });
  })
