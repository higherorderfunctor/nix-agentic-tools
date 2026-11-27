{
  devenvConfig,
  devenvModules,
  homeManagerConfig,
  homeManagerModules,
  index,
  lib,
  packages,
  pkgs,
  registry,
  ...
}: let
  owner = builtins.head (builtins.filter (candidate: candidate.name == "git-revise") index.owners);
  metadata =
    map (entry: [
      (lib.removePrefix "${toString ./.}/" (toString entry.source))
      entry.kind
    ])
    owner.metadata;
  package = packages.ai.gitTools.git-revise;
  sentinel = "facet-input-sentinel";
in {
  checks = {
    git-revise-production-boundary = assert lib.isDerivation package;
    assert package.passthru.fixtureSentinel == sentinel;
    assert registry.facetMock.entries.git-revise.payload == sentinel;
    assert devenvModules == [./modules/devenv];
    assert homeManagerModules == [./modules/homeManager];
    assert homeManagerConfig.facetMock.shared
    == {
      backend = "home-manager";
      enabled = true;
      label = "git-revise";
    };
    assert devenvConfig.facetMock.shared
    == {
      backend = "devenv";
      enabled = true;
      label = "git-revise";
    };
    # Check the recorded sources without importing the metadata-only sidecars.
    assert metadata
    == [
      ["README.md" "documentation"]
      ["default.nix" "owner-default"]
      ["docs" "docs"]
      ["fragments" "fragments"]
      ["module-spec.nix" "nix-sidecar"]
      ["sidecar.nix" "nix-sidecar"]
      ["sources.json" "data-sidecar"]
    ];
      pkgs.runCommandLocal "facet-git-revise-production-boundary" {
        nativeBuildInputs = [package];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        test "$(cat ${package}/marker)" = ${lib.escapeShellArg sentinel}
        mkdir -p "$out"
        touch "$out/passed"
      '';
  };
}
