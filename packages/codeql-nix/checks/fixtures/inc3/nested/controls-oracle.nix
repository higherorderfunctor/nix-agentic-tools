# Independent upstream controls: never imports the adapter or supervisor.
{
  nixpkgs,
  source,
}: let
  lib = import (nixpkgs + "/lib");
  result = lib.evalModules {
    modules = [(source + "/options.nix") (source + "/values.nix")];
  };
  metadata = option: {
    definitions = map (definition: definition.file) option.definitionsWithLocations;
    inherit (option) isDefined;
    priority =
      if option.isDefined
      then toString option.highestPrio
      else null;
  };
  services = result.options.services.valueMeta.attrs."a.b".configuration.options.answer;
  lazy = result.options.lazy.valueMeta.attrs;
  nested = result.options.nested.valueMeta.configuration.options.inner.valueMeta.configuration.options.answer;
  items = result.options.items.valueMeta.list;
  itemCount = builtins.toString (builtins.length items);
  hugeIndex = "9223372036854775808";
  hugeInRange =
    builtins.stringLength hugeIndex
    < builtins.stringLength itemCount
    || (
      builtins.stringLength hugeIndex
      == builtins.stringLength itemCount
      && hugeIndex < itemCount
    );
in {
  hugeIndex = {inherit hugeInRange;};
  lazyAbsent = {
    present = lazy ? absent;
    valueSuccess = (builtins.tryEval (builtins.seq result.config.lazy.poison {success = true;})).success;
  };
  multiStep =
    metadata nested
    // {
      value = result.config.nested.inner.answer;
    };
  siblingThrow =
    metadata services
    // {
      valueSuccess = (builtins.tryEval (builtins.seq result.config.services.poison.answer {success = true;})).success;
    };
}
