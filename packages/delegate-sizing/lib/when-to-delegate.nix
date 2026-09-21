# cspell:ignore highestPrio
{
  lib,
  renames,
}: let
  textSourceOptions = import ../../../lib/mkTextSourceOptions.nix {inherit lib;};
  entryType = lib.types.submodule ({
    config,
    name,
    options,
    ...
  }: {
    imports = [(textSourceOptions.submodule "the delegation guidance")];
    options = {
      _collisionWarning = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        internal = true;
        visible = false;
      };
      _renamedFrom = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        internal = true;
        visible = false;
      };
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to include this delegation guidance in the always-on rule.";
      };
    };

    config._collisionWarning = lib.mkIf (
      !config.enable
      && options.enable.highestPrio > 100
      && (options.text.highestPrio <= 100 || options.source.highestPrio <= 100)
    ) "ai.programs.delegate-sizing.whenToDelegate.${name} collides with a package preset that defaults to off; choose a different name or set enable = true.";
  });
in {
  inherit (textSourceOptions) assertions;
  mkPreset = args @ {
    source ? null,
    text ? null,
  }:
    if args ? source && args ? text
    then throw "whenToDelegate.mkPreset accepts exactly one of `source` or `text`; passing both would define them at the same priority and trigger the text/source conflict assertion"
    else if !(args ? source) && !(args ? text)
    then throw "whenToDelegate.mkPreset requires exactly one of `source` or `text`"
    else
      {
        enable = lib.mkDefault false;
      }
      // (
        if args ? source
        then {source = lib.mkDefault source;}
        else {text = lib.mkDefault text;}
      );
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
  warnings = entries: let
    collisionWarnings = builtins.filter (warning: warning != null) (
      lib.mapAttrsToList (_: entry: entry._collisionWarning) entries
    );
    renameWarnings = lib.concatLists (lib.mapAttrsToList (newName: entry:
      map (oldName: "ai.programs.delegate-sizing.whenToDelegate.${oldName} has been renamed to ai.programs.delegate-sizing.whenToDelegate.${newName}; update the attribute name.")
      (lib.unique entry._renamedFrom))
    entries);
  in
    collisionWarnings ++ renameWarnings;
}
