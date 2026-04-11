# Thin wrapper over upstream flake overlay.
#
# The upstream flake (github:arxanas/git-branchless) provides an overlay
# that overrideAttrs nixpkgs' git-branchless with HEAD source and
# importCargoLock. We layer adjustments on top:
#
# 1. Null postPatch — nixpkgs base has a postPatch that patches the vendored
#    esl01-indexedlog crate, but upstream's Cargo.lock no longer includes it.
#
# 2. Strip versionCheckHook — upstream overlay sets name but not version in
#    overrideAttrs, so the binary version string may not match the derivation
#    version.
#
# Updated via `nix flake update git-branchless` (not nix-update).
{
  inputs,
  final,
  ...
}: let
  # Apply upstream's overlay to get their overridden git-branchless.
  upstreamPkgs = inputs.git-branchless.overlays.default final final;
in
  upstreamPkgs.git-branchless.overrideAttrs (prev: {
    postPatch = "";
    nativeInstallCheckInputs =
      builtins.filter
      (p: (p.pname or "") != "version-check-hook")
      (prev.nativeInstallCheckInputs or []);
  })
