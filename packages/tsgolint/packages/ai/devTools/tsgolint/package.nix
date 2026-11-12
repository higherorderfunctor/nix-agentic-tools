# tsgolint — HEAD-tracked type-aware linting backend for oxlint.
# Thin overrideAttrs of nixpkgs' tsgolint: swap src (main rev, submodules),
# version, and vendorHash; inherit the typescript-go submodule patch dance.
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

  rev = "1ae4bbd516db0a7a5390e86c90623dc343dea1e6";
  src = pkgs.fetchFromGitHub {
    owner = "oxc-project";
    repo = "tsgolint";
    inherit rev;
    hash = "sha256-QVku5QmZNkiLIz53s34tyvMK+UDjYYgvtLpUjOVAiYE=";
    fetchSubmodules = true;
  };
in
  (toolchain.overridePackage pkgs.tsgolint).overrideAttrs (_finalAttrs: prev: {
    version = vu.mkVersion {
      upstream = "0.25.0-unstable"; # newest tag base from Step 1
      inherit rev;
    };
    inherit src;
    passthru = (prev.passthru or {}) // toolchain.passthru;
    vendorHash = "sha256-Xt3Coh+Q2VneVz+PfnT80sN9FAlMZbvPWxYWQUuGXYo=";
  })
