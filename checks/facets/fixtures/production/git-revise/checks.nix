{
  devenvModules,
  homeManagerModules,
  index,
  lib,
  pkgs,
  registry,
  ...
}: let
  inherit (lib) assertMsg;
  owner = builtins.head (builtins.filter (candidate: candidate.name == "git-revise") index.owners);
  metadata =
    map (entry: lib.removePrefix "${toString ./.}/" (toString entry.source))
    owner.metadata;
  sentinel = "facet-input-sentinel";
in {
  checks = {
    git-revise-production-boundary = assert assertMsg (registry.facetMock.entries.git-revise.payload == sentinel) "registry must resolve the input-backed value over the same-owner default";
    assert assertMsg (devenvModules == [./modules/devenv]) "devenv discovery must return only the raw devenv module directory";
    assert assertMsg (homeManagerModules == [./modules/homeManager]) "Home Manager discovery must return only the raw Home Manager module directory";
    # Check the recorded sources without importing the metadata-only sidecars.
    assert assertMsg (metadata
      == [
        "README.md"
        "default.nix"
        "docs"
        "fragments"
        "sidecar.nix"
        "sources.json"
      ]) "discovery must record exactly the git-revise metadata source paths";
      pkgs.runCommandLocal "facet-git-revise-production-boundary" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        mkdir -p "$out"
        touch "$out/passed"
      '';
  };
}
