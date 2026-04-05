# Git tools overlay — git-absorb, git-branchless, git-revise.
# Packages exposed at top-level (pkgs.git-absorb, etc.) per interface contract.
#
# Requires rust-overlay for Rust toolchain (git-absorb, git-branchless).
{inputs, ...}: let
  inherit (inputs.nixpkgs) lib;

  # Evaluate sources once per composition, pass to all overlays.
  withSources = overlayPaths: final: prev: let
    sources = import ./sources.nix {
      inherit (final) fetchurl fetchgit fetchFromGitHub dockerTools;
    };
    applyOverlay = path: (import path) sources final prev;
  in
    lib.foldl' lib.recursiveUpdate {} (map applyOverlay overlayPaths);

  localOverlays = [
    ./git-absorb.nix
    ./git-branchless.nix
    ./git-revise.nix
  ];
in
  lib.composeManyExtensions
  [inputs.rust-overlay.overlays.default (withSources localOverlays)]
