# tsgolint — HEAD-tracked type-aware linting backend for oxlint, pinned
# against `ourPkgs` (this repo's nixpkgs) for cache-hit parity. Thin
# overrideAttrs of nixpkgs' tsgolint: swap src (main rev, submodules),
# version, and vendorHash; inherit the typescript-go submodule patch dance.
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  vu = import ../lib.nix;

  rev = "ef193195a389b21108b6862853c71f924aaa372c";
  src = ourPkgs.fetchFromGitHub {
    owner = "oxc-project";
    repo = "tsgolint";
    inherit rev;
    hash = "sha256-4BVA/nXJi198XmvLCiMvmPTy9SVOCS5MiF6QAZNTAHE=";
    fetchSubmodules = true;
  };
in
  ourPkgs.tsgolint.overrideAttrs (_finalAttrs: _prev: {
    version = vu.mkVersion {
      upstream = "0.25.0-unstable"; # newest tag base from Step 1
      inherit rev;
    };
    inherit src;
    vendorHash = "sha256-hlm9KvlNTrtDD2cRxb+Ir/LPNv6qNN/NBA/+Q9yhhH8=";
  })
