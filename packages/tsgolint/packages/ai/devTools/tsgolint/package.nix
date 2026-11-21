# tsgolint — HEAD-tracked type-aware linting backend for oxlint.
# Override nixpkgs' tsgolint for oxlint and the standalone package. Use the
# pinned tsgolint source for both the typescript-go submodule and its patches.
{
  pkgs,
  packageLib,
  repoPath,
  ...
}: let
  vu = packageLib;

  goFloor = "1.26.10";
  toolchain = vu.mkGoToolchain {
    floor = goFloor;
    inherit pkgs;
    pname = "tsgolint";
    recipeFile = repoPath ./package.nix;
  };

  rev = "eac99bdcc87d40667bcb68bcd746c99e8943731a";
  src = pkgs.fetchFromGitHub {
    owner = "oxc-project";
    repo = "tsgolint";
    inherit rev;
    hash = "sha256-RdQirmCLPYpALsnrbprS4t/D/9dhsg6nUEjxkvCSmCc=";
    fetchSubmodules = true;
  };
in
  (toolchain.overridePackage pkgs.tsgolint).overrideAttrs (finalAttrs: prev: {
    version = vu.mkVersion {
      upstream = "0.25.0-unstable"; # newest tag base from Step 1
      inherit rev;
    };
    inherit src;
    inherit (packageLib) patchFlags;
    patches = [];
    # nixpkgs enters typescript-go before patching and copies collections out
    # afterward. Discover the series here once stdenv has unpacked the source.
    prePatch =
      prev.prePatch
      + ''
        (
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          shopt -s failglob
          export LC_ALL=C
          for patchFile in ../patches/*.patch; do
            echo "applying patch $patchFile"
            patch ${pkgs.lib.escapeShellArgs finalAttrs.patchFlags} < "$patchFile"
          done
        )
      '';
    passthru = (prev.passthru or {}) // toolchain.passthru;
    vendorHash = "sha256-Xt3Coh+Q2VneVz+PfnT80sN9FAlMZbvPWxYWQUuGXYo=";
  })
