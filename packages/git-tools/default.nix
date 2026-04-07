# Git tools overlay — git-absorb, git-branchless, git-revise.
# Packages exposed at top-level (pkgs.git-absorb, etc.) per interface contract.
#
# Threads `inputs` into per-package overlay functions so each can
# instantiate its own `ourPkgs = import inputs.nixpkgs { ... }`
# (cache-hit parity pattern — see
# dev/notes/overlay-cache-hit-parity-fix.md and the
# `overlays/cache-hit-parity.md` fragment). Per-package files that
# don't yet consume `inputs` still accept it structurally via a
# new first curried arg; Phase 3.3 of the architecture-foundation
# plan rewrites each Rust package to actually use it.
#
# `rust-overlay` is still composed at the top level for now. It
# will be dropped in Phase 3.3 once each Rust package applies
# rust-overlay to its own `ourPkgs` internally — at that point
# keeping it at the top level would double-apply and couple the
# toolchain to the consumer's nixpkgs. For this plumbing-only
# commit, removing it prematurely would break `final.rust-bin`
# references in agnix/git-absorb/git-branchless and change the
# set of failing checks.
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
  lib.composeManyExtensions
  [inputs.rust-overlay.overlays.default (withSources localOverlays)]
