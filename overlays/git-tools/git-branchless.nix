# git-branchless — HEAD source + importCargoLock, pinned against
# `ourPkgs` (this repo's nixpkgs) for cache-hit parity.
#
# The upstream flake (github:arxanas/git-branchless) provides an
# overlay that does the `overrideAttrs` + `importCargoLock` dance
# against `final` — the consumer's pkgs. That binds build inputs
# to the consumer's nixpkgs pin, so consumers with a different
# pin cache-miss against `nix-agentic-tools.cachix.org`. We
# re-implement the same overrides here against `ourPkgs` so the
# derivation hash only depends on this repo's pin.
#
# Local adjustments preserved from the previous thin-wrapper
# version:
#   1. Null postPatch — nixpkgs base has a postPatch that patches
#      the vendored esl01-indexedlog crate, but upstream's
#      Cargo.lock no longer includes it.
#   2. Strip versionCheckHook — we set `name` in the override but
#      not `version`, so the binary version string may not match
#      the derivation version. Filter the hook out of
#      nativeInstallCheckInputs to avoid a mismatch failure.
#
# Source + Cargo.lock come from `inputs.git-branchless` (the
# flake source), same data the upstream overlay uses. Updated via
# `nix flake update git-branchless` (not nix-update).
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  gbSrc = inputs.git-branchless;
in
  ourPkgs.git-branchless.overrideAttrs (prev: {
    name = "git-branchless";
    src = gbSrc;
    cargoDeps = ourPkgs.rustPlatform.importCargoLock {
      lockFile = gbSrc + "/Cargo.lock";
    };
    postPatch = "";
    nativeInstallCheckInputs =
      builtins.filter
      (p: (p.pname or "") != "version-check-hook")
      (prev.nativeInstallCheckInputs or []);
    meta =
      (removeAttrs prev.meta ["maintainers"])
      // {
        # Re-inherit description to regenerate meta.position so
        # back traces point at this override, not the base
        # nixpkgs definition.
        inherit (prev.meta) description;
      };
  })
