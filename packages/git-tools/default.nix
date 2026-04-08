# Git tools overlay — git-absorb, git-branchless, git-revise.
# Packages exposed at top-level (pkgs.git-absorb, etc.) per interface contract.
#
# Threads `inputs` into per-package overlay functions so each can
# instantiate its own `ourPkgs = import inputs.nixpkgs { ... }`
# (cache-hit parity pattern — see
# dev/notes/overlay-cache-hit-parity-fix.md and the
# `overlays/cache-hit-parity.md` fragment). Each Rust package
# applies `rust-overlay` internally to its own `ourPkgs`, so we
# intentionally do NOT compose `inputs.rust-overlay.overlays.default`
# at this layer — doing so would couple the toolchain to the
# consumer's nixpkgs and defeat the parity work.
{inputs, ...}: let
  inherit (inputs.nixpkgs) lib;

  # Evaluate sources once per composition, pass to all overlays.
  withSources = overlayPaths: final: prev: let
    sources = import ./sources.nix {
      inherit (final) fetchurl fetchgit fetchFromGitHub dockerTools;
    };
    # Thread `inputs` into each per-package overlay so it can
    # instantiate its own `ourPkgs = import inputs.nixpkgs`.
    applyOverlay = path: (import path) {inherit inputs;} sources final prev;
  in
    lib.foldl' lib.recursiveUpdate {} (map applyOverlay overlayPaths);

  localOverlays = [
    ./agnix.nix
    ./git-absorb.nix
    ./git-branchless.nix
    ./git-revise.nix
  ];
in
  withSources localOverlays
