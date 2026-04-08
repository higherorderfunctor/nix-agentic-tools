# Git tools overlay — git-absorb, git-branchless, git-revise.
# Packages exposed at top-level (`pkgs.git-absorb`, etc.) per the
# overlay interface contract.
#
# 3-argument overlay shape (`{inputs, ...}: final: prev: ...`) per
# `dev/fragments/overlays/overlay-pattern.md` — the inputs blob is
# threaded into per-package overlays so each can instantiate its
# own `ourPkgs = import inputs.nixpkgs { ... }` (cache-hit parity
# pattern).
#
# Each Rust package applies `inputs.rust-overlay.overlays.default`
# internally to its own `ourPkgs`, so we intentionally do NOT
# compose `rust-overlay` at this layer — doing so would couple
# the toolchain to the consumer's nixpkgs and defeat the parity
# work.
{inputs, ...}: final: prev: let
  inherit (inputs.nixpkgs) lib;

  # Sources are read from `final.nv-sources` (set up by the
  # nv-sources overlay in `flake.nix`) and merged with the
  # local `hashes.json` sidecar that holds cargoHash entries
  # nvfetcher can't compute itself.
  sources = import ./sources.nix {inherit (final) nv-sources;};

  # Per-package overlays receive `(inputs, sources)` as the
  # outer args and `(final, prev)` as the inner overlay
  # function args.
  applyOverlay = path: (import path) {inherit inputs;} sources final prev;

  localOverlays = [
    ./git-absorb.nix
    ./git-branchless.nix
    ./git-revise.nix
  ];
in
  lib.foldl' lib.recursiveUpdate {} (map applyOverlay localOverlays)
