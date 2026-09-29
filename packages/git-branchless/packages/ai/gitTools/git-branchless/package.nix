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
#
# `passthru.extracted` is the config-key census of the PATCHED source
# (packages/git-branchless/docs/extraction.md). passthru is not a
# derivation input, so it does not move this package's store path.
{
  inputs,
  packageLib,
  pkgs,
  repoPath,
  ...
}: let
  ourPkgs = pkgs;
  gbSrc = inputs.git-branchless;
  extractFile = name: ../../../../extract + "/${name}";

  # Unpack + patch of the package's own `src` and `patches`: the patch adds
  # a key (`branchless.core.protectCheckedOutBranches`) the upstream tree
  # does not read. stdenvNoCC keeps the Rust toolchain and the vendored
  # crates out of the extraction's inputs.
  patchedSource = ourPkgs.srcOnly {
    inherit (package) patches postPatch src;
    name = "git-branchless-patched";
    stdenv = ourPkgs.stdenvNoCC;
  };

  # Fails on any guard (extract.py's header lists them), so an upstream
  # change the resolver does not understand stops the build instead of
  # dropping a key.
  extracted =
    ourPkgs.runCommand "git-branchless-extracted.json" {
      nativeBuildInputs = [ourPkgs.ast-grep ourPkgs.python3];
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      cd ${patchedSource}
      ast-grep scan --rule ${extractFile "rules/config.yml"} --json=stream . >"$TMPDIR/matches.jsonl"
      python3 ${extractFile "extract.py"} \
        --annotations ${extractFile "annotations.json"} \
        --matches "$TMPDIR/matches.jsonl" \
        --out "$out" \
        --src ${patchedSource}
    '';

  package = ourPkgs.git-branchless.overrideAttrs (prev: {
    name = "git-branchless";
    src = gbSrc;
    cargoDeps = ourPkgs.rustPlatform.importCargoLock {
      lockFile = gbSrc + "/Cargo.lock";
    };
    patches = (prev.patches or []) ++ [../../../../patches/protect-checked-out-branches.patch];
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
        regenerateExtracted = packageLib.mkFlakeInputRegen {
          name = "git-branchless";
          pkgs = ourPkgs;
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
