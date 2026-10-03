# git-branchless — HEAD source + importCargoLock, pinned against
# `pkgs` (this repo's nixpkgs) for cache-hit parity.
#
# The upstream flake (github:arxanas/git-branchless) provides an
# overlay that does the `overrideAttrs` + `importCargoLock` dance
# against `final` — the consumer's pkgs. That binds build inputs
# to the consumer's nixpkgs pin, so consumers with a different
# pin cache-miss against `nix-agentic-tools.cachix.org`. We
# re-implement the same overrides here against `pkgs` so the
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
# Patches (packages/git-branchless/patches/), re-check on every bump:
#   protect-checked-out-branches — refuse to move a branch another
#     worktree has checked out (`branchless.core.protectCheckedOutBranches`).
#   repair-idempotent — `git branchless repair` skips commits it already
#     obsoleted; upstream re-reports and re-obsoletes them on every run.
#
# Source + Cargo.lock come from `inputs.git-branchless` (the
# flake source), same data the upstream overlay uses. Updated via
# `nix flake update git-branchless` (not nix-update).
#
# `passthru.extracted` is the config-key census of the PATCHED source
# (packages/git-branchless/docs/extraction.md). passthru is not a
# derivation input, so it does not move this package's store path.
{
  gitToolExtraction,
  inputs,
  packageLib,
  pkgs,
  repoPath,
  ...
}: let
  rustPlatform = packageLib.mkRustPlatform {inherit pkgs;};
  gbSrc = inputs.git-branchless;
  extraction = gitToolExtraction {inherit pkgs;};

  # Unpack + patch of the package's own `src` and `patches`: the
  # checked-out-branch patch adds a key
  # (`branchless.core.protectCheckedOutBranches`) the upstream tree does not
  # read.
  patchedSource = extraction.patchedSource {
    name = "git-branchless";
    inherit package;
  };

  # Fails on any guard (extract.py's header lists them), so an upstream
  # change the tree walk does not understand stops the build instead of
  # dropping a key.
  extracted = extraction.extracted {
    name = "git-branchless";
    source = patchedSource;
    extractDir = ../../../../extract;
  };

  package = (pkgs.git-branchless.override {inherit rustPlatform;}).overrideAttrs (prev: {
    name = "git-branchless";
    src = gbSrc;
    cargoDeps = rustPlatform.importCargoLock {
      lockFile = gbSrc + "/Cargo.lock";
    };
    patches =
      (prev.patches or [])
      ++ [
        ../../../../patches/protect-checked-out-branches.patch
        ../../../../patches/repair-idempotent.patch
      ];
    postPatch = "";
    nativeInstallCheckInputs =
      builtins.filter
      (p: (p.pname or "") != "version-check-hook")
      (prev.nativeInstallCheckInputs or []);
    passthru =
      (prev.passthru or {})
      // {
        inherit extracted patchedSource;
        # Source and Cargo.lock move with the normal flake-input sweep,
        # which also runs `regenerateExtracted` so the bump PR carries the
        # refreshed sidecar.
        regenerateExtracted = packageLib.mkRegenerateExtracted {
          name = "git-branchless";
          inherit pkgs;
          targets = [
            {
              attr = "git-branchless";
              dest = repoPath ../../../../extracted.json;
            }
          ];
        };
        updateFlakeInput = "git-branchless";
      };
    meta =
      (removeAttrs prev.meta ["maintainers"])
      // {
        # Re-inherit description to regenerate meta.position so
        # back traces point at this override, not the base
        # nixpkgs definition.
        inherit (prev.meta) description;
      };
  });
in
  package
