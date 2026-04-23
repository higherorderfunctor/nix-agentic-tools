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

  vu = import ../lib.nix;

  rust = ourPkgs.rust-bin.stable.latest.default;
  rustPlatform = ourPkgs.makeRustPlatform {
    cargo = rust;
    rustc = rust;
  };

  rev = "debdcd28d9db2ac6b36205bda307b6693a6a91e7";
  src = fetchFromGitHub {
    owner = "tummychow";
    repo = "git-absorb";
    inherit rev;
    hash = "sha256-jAR+Vq6SZZXkseOxZVJSjsQOStIip8ThiaLroaJcIfc=";
  };
in
  ourPkgs.git-absorb.override (_: {
    rustPlatform.buildRustPackage = args:
      rustPlatform.buildRustPackage (finalAttrs: let
        a = (ourPkgs.lib.toFunction args) finalAttrs;
      in
        a
        // {
          version = vu.mkVersion {
            # upstream: readCargoVersion @ Cargo.toml
            upstream = "0.9.0";
            inherit rev;
          };
          inherit src;
          cargoHash = "sha256-8uCXk5bXn/x4QXbGOROGlWYMSqIv+/7dBGZKbYkLfF4=";
          doInstallCheck = true;
          installCheckPhase = ''
            runHook preInstallCheck
            $out/bin/git-absorb --version
            runHook postInstallCheck
          '';
        });
  })
