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

  rev = "f69fe736c07178de4ca43abff1ec86599acab672";
  src = pkgs.fetchFromGitHub {
    owner = "oxc-project";
    repo = "tsgolint";
    inherit rev;
    hash = "sha256-QocyitopXv91BXo+1V1A/qpJ0ig3AGOXOX6AGkWaAfI=";
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
    vendorHash = "sha256-X+JPv4SLJXyF938H34ldDgK2XsuORbDxbWhJ0svYTAs=";
  })
