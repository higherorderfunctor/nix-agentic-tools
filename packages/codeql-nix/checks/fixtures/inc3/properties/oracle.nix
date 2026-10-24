# Independent upstream evaluator: never imports the adapter or fact producer.
{
  nixpkgs,
  source,
  modules,
  forceValue ? false,
  overrideLib ? false,
}: let
  lib = import (nixpkgs + "/lib");
  supplied = lib // {mkBefore = _: ["override-sentinel"];};
  result = lib.evalModules {
    modules = map (name: source + "/" + name + ".nix") modules;
    specialArgs = lib.optionalAttrs overrideLib {lib = supplied;};
  };
  option = result.options.demo.items;
in
  if forceValue
  then result.config.demo.items
  else {
    definitions =
      map (definition: {
        inherit (definition) file;
        order =
          if definition ? priority
          then toString definition.priority
          else null;
      })
      option.definitionsWithLocations;
    inherit (option) isDefined;
    priority =
      if option.isDefined
      then toString option.highestPrio
      else null;
  }
