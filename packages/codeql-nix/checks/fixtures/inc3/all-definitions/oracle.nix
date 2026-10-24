# Independent upstream evaluator: never imports the adapter or fact producer.
{
  nixpkgs,
  source,
  modules,
  forceValue ? false,
  internalKey ? false,
  specialLib ? false,
}: let
  lib = import (nixpkgs + "/lib");
  supplied =
    lib
    // {
      mkDefault = _: 2;
    };
  result = lib.evalModules {
    modules = map (name: source + "/" + name + ".nix") modules;
    specialArgs = lib.optionalAttrs specialLib {lib = supplied;};
  };
  option = result.options.demo.answer;
in
  if internalKey
  then result.options._module.args.declarations
  else if forceValue
  then result.config.demo.answer
  else {
    definitions = map (definition: {inherit (definition) file;}) option.definitionsWithLocations;
    inherit (option) isDefined;
    priority = toString option.highestPrio;
  }
