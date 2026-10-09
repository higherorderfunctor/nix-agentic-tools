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

  rev = "8d4c05c9245c1f67a7419b596001dd5ac55d585e";
  src = pkgs.fetchFromGitHub {
    owner = "oxc-project";
    repo = "tsgolint";
    inherit rev;
    hash = "sha256-jK7wyz58pvw5S5RPpWy3XbpDNhMOzQtzioY0gD+lXTs=";
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
    vendorHash = "sha256-hpKAZexYdxWh0h5e60jHUQ808xBt7XGuXQBs1ZYgdzw=";
  })
