# Independent upstream evaluator: never imports the adapter or fact producer.
{
  nixpkgs,
  source,
  modules,
  path ? ["new"],
  specialLib ? false,
  witnessPaths ? [],
}: let
  lib = import (nixpkgs + "/lib");
  supplied = lib // {mkRenamedOptionModule = _from: _to: {config.new = 111;};};
  result = lib.evalModules {
    modules = map (name: source + "/" + name + ".nix") modules;
    specialArgs = lib.optionalAttrs specialLib {lib = supplied;};
  };
  option = lib.getAttrFromPath path result.options;
in {
  value = lib.getAttrFromPath path result.config;
  warnings = result.config.warnings or [];
  values = map (segments: lib.getAttrFromPath segments result.config) witnessPaths;
  destinationFiles = map (definition: definition.file) option.definitionsWithLocations;
}
