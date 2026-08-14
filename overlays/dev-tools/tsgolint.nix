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

  rev = "92e0f4dac8eb767bd6ed523c934f798bf44d755e";
  src = ourPkgs.fetchFromGitHub {
    owner = "oxc-project";
    repo = "tsgolint";
    inherit rev;
    hash = "sha256-Dkmp/LV9FcI2OVW7eT9ei0YEcluQT1aAXG+XRRqVUb4=";
    fetchSubmodules = true;
  };
in
  ourPkgs.tsgolint.overrideAttrs (_finalAttrs: _prev: {
    version = vu.mkVersion {
      upstream = "0.25.0-unstable"; # newest tag base from Step 1
      inherit rev;
    };
    inherit src;
    vendorHash = "sha256-orVgfCcc9dXHvso4RCmYnSnb0THC+++sS9Y4pKhn4vU=";
  })
