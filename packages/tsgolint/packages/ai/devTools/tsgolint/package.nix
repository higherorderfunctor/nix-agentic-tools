# tsgolint — HEAD-tracked type-aware linting backend for oxlint, pinned
# against `ourPkgs` (this repo's nixpkgs) for cache-hit parity. Thin
# overrideAttrs of nixpkgs' tsgolint: swap src (main rev, submodules),
# version, and vendorHash; inherit the typescript-go submodule patch dance.
{
  pkgs,
  packageLib,
  ...
}: let
  ourPkgs = pkgs;
  vu = packageLib;

  rev = "acd88e1b1ef8f219e8956f804f2548dafd949705";
  src = ourPkgs.fetchFromGitHub {
    owner = "oxc-project";
    repo = "tsgolint";
    inherit rev;
    hash = "sha256-KJJzSRk+S5XCp8AnIFUZKdkUsH2eLlu1Uzyu5zZmIS8=";
    fetchSubmodules = true;
  };
in
  ourPkgs.tsgolint.overrideAttrs (_finalAttrs: _prev: {
    version = vu.mkVersion {
      upstream = "0.25.0-unstable"; # newest tag base from Step 1
      inherit rev;
    };
    inherit src;
    vendorHash = "sha256-X+JPv4SLJXyF938H34ldDgK2XsuORbDxbWhJ0svYTAs=";
  })
