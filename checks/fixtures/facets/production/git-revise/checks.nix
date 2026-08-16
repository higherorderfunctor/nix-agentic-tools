{
  devenvConfig,
  devenvModules,
  homeManagerConfig,
  homeManagerModules,
  index,
  inputs,
  lib,
  packages,
  pkgs,
  registry,
  self,
  system,
  ...
}: let
  owner = builtins.head (builtins.filter (candidate: candidate.name == "git-revise") index.owners);
  metadataKinds = builtins.map (entry: entry.kind) owner.metadata;
  package = packages.git-revise;
in {
  git-revise-production-boundary = assert lib.isDerivation package;
  assert package.passthru.fixtureSentinel == inputs.fixture.sentinel;
  assert registry.facetMock.entries.git-revise.payload == inputs.fixture.sentinel;
  assert builtins.elem owner.contributions.modules.homeManager.source homeManagerModules;
  assert builtins.elem owner.contributions.modules.devenv.source devenvModules;
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
  assert builtins.elem "owner-default" metadataKinds;
  assert builtins.elem "documentation" metadataKinds;
  assert builtins.elem "docs" metadataKinds;
  assert builtins.elem "fragments" metadataKinds;
  assert builtins.elem "nix-sidecar" metadataKinds;
  assert builtins.elem "data-sidecar" metadataKinds;
  assert !(self.packages.${system} ? git-revise-fixture);
    pkgs.runCommandLocal "facet-git-revise-production-boundary" {
      nativeBuildInputs = [package];
    } ''
      test "$(cat ${package}/marker)" = ${lib.escapeShellArg inputs.fixture.sentinel}
      mkdir -p "$out"
      touch "$out/passed"
    '';
}
