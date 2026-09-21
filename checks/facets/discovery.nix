{
  inputs,
  lib,
  pkgs,
  self,
  ...
}: let
  modelName = "qwen3-embedding-0.6b-q8_0";
  consumer = import inputs.nixpkgs {
    inherit (pkgs.stdenv.hostPlatform) system;
    overlays = [self.overlays.default];
  };
  discover = import ../../lib/testing/discover.nix {inherit lib;};
  world = (import ../../lib/facets.nix {inherit lib;}).realizeChecks {
    context = {inherit lib pkgs;};
    index.owners = [];
    rootModules = discover ./discovery-fixtures;
  };
in {
  checks.facet-check-discovery = assert consumer.models.${modelName}.drvPath == self.packages.${pkgs.stdenv.hostPlatform.system}.${modelName}.drvPath;
  assert self.updateTargets.${modelName}.flags == ["--use-update-script"];
  assert builtins.attrNames world.checks == ["discovered"];
    pkgs.runCommandLocal "facet-check-discovery" {} ''
      test -e ${world.checks.discovered}
      touch "$out"
    '';
}
