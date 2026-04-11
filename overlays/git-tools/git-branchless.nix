# Thin wrapper over upstream flake overlay.
#
# The upstream flake (github:arxanas/git-branchless) provides an overlay
# that overrideAttrs nixpkgs' git-branchless with HEAD source and
# importCargoLock. We layer two adjustments on top:
#
# 1. Rust 1.88.0 pin — esl01-indexedlog workaround (arxanas/git-branchless#1585).
#    NOTE: upstream master replaced esl01-indexedlog with sapling-indexedlog,
#    so this pin may be removable once confirmed safe on Rust 1.89+.
#
# 2. Null postPatch — nixpkgs base has a postPatch that patches the vendored
#    esl01-indexedlog crate, but upstream's Cargo.lock no longer includes it.
#    Without nulling this, the build fails trying to cd into a non-existent dir.
#
# 3. Strip versionCheckHook — upstream overlay sets name but not version in
#    overrideAttrs, so the binary version string may not match the derivation
#    version. Disable the install check to avoid false failures.
#
# Updated via `nix flake update git-branchless` (not nix-update).
{
  inputs,
  final,
  ...
}: let
  # Apply upstream's overlay to get their overridden git-branchless.
  upstreamPkgs = inputs.git-branchless.overlays.default final final;

  # Rust 1.88.0 pin for cache-hit parity — see dev/fragments/overlays/cache-hit-parity.md
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
    overlays = [inputs.rust-overlay.overlays.default];
  };
  rust = ourPkgs.rust-bin.stable."1.88.0".default;
  rustPlatform = ourPkgs.makeRustPlatform {
    cargo = rust;
    rustc = rust;
  };
in
  (upstreamPkgs.git-branchless.override {
    inherit rustPlatform;
  })
  .overrideAttrs (prev: {
    # Null nixpkgs' esl01-indexedlog patch — upstream no longer vendors it.
    postPatch = "";
    # Strip versionCheckHook to avoid version string mismatch.
    nativeInstallCheckInputs =
      builtins.filter
      (p: (p.pname or "") != "version-check-hook")
      (prev.nativeInstallCheckInputs or []);
  })
