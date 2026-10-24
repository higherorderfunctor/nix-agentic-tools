# Independent upstream evaluator: never imports the adapter or fact producer.
{
  case,
  leaf,
  listModules ? ["first" "second"],
  member,
  nixpkgs,
  source,
  forceValue ? false,
}: let
  lib = import (nixpkgs + "/lib");
  file = name: source + "/${name}.nix";
  result = lib.evalModules {
    modules =
      if case == "direct"
      then [(file "direct-options") (file "direct")]
      else if case == "list"
      then [(file "list-options")] ++ map file listModules
      else if case == "freeform"
      then [(file "freeform-options") (file "hosts")]
      else [(file "options") (file "hosts")];
  };
  rootOption =
    if case == "direct"
    then result.options.unit
    else if case == "list"
    then result.options.items
    else result.options.services;
  meta = rootOption.valueMeta or {};
  # Availability comes from upstream rich metadata, never from the fixture name.
  members =
    if case == "list"
    then meta.list or null
    else meta.attrs or null;
  shaped =
    if case == "list"
    then builtins.isList members
    else builtins.isAttrs members;
  present =
    if case == "list"
    then builtins.fromJSON member < builtins.length members
    else builtins.hasAttr member members;
  entry =
    if case == "direct"
    then meta
    else if case == "list"
    then builtins.elemAt members (builtins.fromJSON member)
    else members.${member};
  refusal =
    if case != "direct" && !shaped
    then "M3n nested-metadata-unavailable"
    else if case != "direct" && !present
    then "M3n instance-unavailable"
    else if !(builtins.isAttrs entry && entry ? configuration)
    then "M3n nested-metadata-unavailable"
    else if !builtins.hasAttr leaf entry.configuration.options
    then "M3n option-unavailable"
    else null;
  option = entry.configuration.options.${leaf};
in
  if forceValue
  then
    (
      if case == "direct"
      then result.config.unit
      else if case == "list"
      then result.config.items
      else result.config.services
    )
  else if refusal != null
  then throw refusal
  else {
    definitions = map (definition: definition.file) option.definitionsWithLocations;
    inherit (option) isDefined;
    priority =
      if option.isDefined
      then toString option.highestPrio
      else null;
  }
