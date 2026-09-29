# Instantiate `ourPkgs` from `inputs.nixpkgs` so every build input
# (rust toolchain, makeRustPlatform, base derivation) routes through
# this repo's pinned nixpkgs instead of the consumer's. This is what
# gives the store path cache-hit parity against CI's standalone build
# — see dev/fragments/overlays/overlay-pattern.md
#
# Argument shape adapted from legacy 3-layer curried pattern during Milestone 6 port.
#
# `passthru.extracted` is the config-key census of the source this recipe
# builds (packages/git-absorb/extract/, lib/git-tool-settings). passthru is
# not a derivation input, so it does not move this package's store path.
{
  inputs,
  pkgs,
  packageLib,
  repoPath,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (pkgs.stdenv.hostPlatform) system;
    overlays = [inputs.rust-overlay.overlays.default];
  };
  inherit (ourPkgs) fetchFromGitHub;

  vu = packageLib;

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
  extraction = import ../../../../../../lib/git-tool-settings/extraction.nix {inherit pkgs;};

  package = ourPkgs.git-absorb.override (_: {
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
  });

  patchedSource = extraction.patchedSource {
    name = "git-absorb";
    inherit package;
  };
in
  package.overrideAttrs (prev: {
    passthru =
      (prev.passthru or {})
      // {
        inherit patchedSource;
        # asciidoc parses Documentation/git-absorb.adoc, the source of the
        # option descriptions, the same way the build turns it into the man
        # page.
        extracted = extraction.extracted {
          name = "git-absorb";
          source = patchedSource;
          extractDir = ../../../../extract;
          tools = [pkgs.asciidoc];
        };
        # A rev bump runs this through dev/scripts/update-pkg.sh, so the bump
        # PR carries the refreshed sidecar.
        regenerateExtracted = packageLib.mkFlakeInputRegen {
          name = "git-absorb";
          inherit pkgs;
          targets = [
            {
              attr = "git-absorb";
              dest = repoPath ../../../../extracted.json;
            }
          ];
        };
      };
  })
