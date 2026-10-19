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

  goFloor = "1.26";
  toolchain = vu.mkGoToolchain {
    floor = goFloor;
    inherit pkgs;
    pname = "tsgolint";
    recipeFile = repoPath ./package.nix;
  };

  rev = "a18037134a44ca331e0e2451e50b2dd2e374acb3";
  src = pkgs.fetchFromGitHub {
    owner = "oxc-project";
    repo = "tsgolint";
    inherit rev;
    hash = "sha256-syUDR32w/UdWQ/ODIzj65N5f7kSbDT5h+iyi2o9q4NI=";
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
