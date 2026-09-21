{
  lib,
  renames,
}: let
  aiTypes = import ../../../lib/ai/types.nix {inherit lib;};
  textSourceType = aiTypes.optionalTextSource {
    description = "the delegation guidance";
  };
  entryType = lib.types.submodule {
    imports = textSourceType.getSubModules;
    options._renamedFrom = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      internal = true;
      visible = false;
    };
  };
in {
  # Default-priority content keeps package presets from auto-enabling themselves.
  mkPreset = args @ {
    source ? null,
    text ? null,
  }:
    if args ? source && args ? text
    then throw "whenToDelegate.mkPreset accepts exactly one of `source` or `text`; passing both would define them at the same priority and trigger the text/source conflict"
    else if !(args ? source) && !(args ? text)
    then throw "whenToDelegate.mkPreset requires exactly one of `source` or `text`"
    else if args ? source
    then {source = lib.mkDefault source;}
    else {text = lib.mkDefault text;};
  rename = entries:
    builtins.foldl' (result: oldName: let
      newName = renames.${oldName};
      oldEntry = result.${oldName};
      newEntry = result.${newName} or {};
      mergedEntry = lib.recursiveUpdate newEntry oldEntry;
    in
      if oldName == newName || !(result ? ${oldName})
      then result
      else
        removeAttrs result [oldName]
        // {
          ${newName} =
            mergedEntry
            // {
              _renamedFrom = lib.unique ((newEntry._renamedFrom or []) ++ (oldEntry._renamedFrom or []) ++ [oldName]);
            };
        })
    entries
    (builtins.attrNames renames);
  type = lib.types.attrsOf entryType;
  warnings = entries:
    lib.concatLists (lib.mapAttrsToList (newName: entry:
      map (oldName: "ai.programs.delegate-sizing.whenToDelegate.${oldName} has been renamed to ai.programs.delegate-sizing.whenToDelegate.${newName}; update the attribute name.")
      (lib.unique entry._renamedFrom))
    entries);
}
