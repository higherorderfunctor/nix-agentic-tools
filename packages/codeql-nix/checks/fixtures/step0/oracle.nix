# Independent upstream module metadata, with no extractor or encoder imports.
{
  nixpkgs,
  source,
  case,
}: let
  lib = import (nixpkgs + "/lib");
  result = lib.evalModules {
    modules =
      [(source + "/options.nix") (source + "/ordinary.nix")]
      ++ {
        equal = [(source + "/equal.nix")];
        failure = [(source + "/failure.nix")];
        ordinary = [(source + "/default.nix")];
        unselected = [(source + "/unselected.nix")];
      }.${
        case
      };
  };
  option = result.options.demo.answer;
in {
  declarations = map builtins.baseNameOf option.declarations;
  files = map (definition: builtins.baseNameOf definition.file) option.definitionsWithLocations;
  priority = toString option.highestPrio;
}
