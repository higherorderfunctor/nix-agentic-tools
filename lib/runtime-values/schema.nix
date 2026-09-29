{lib}: let
  schemaForAt = path: type: let
    base =
      if builtins.elem type.name ["str" "bool" "int" "float"]
      then lib.types.${type.name}
      else if type.name == "enum"
      then lib.types.enum type.functor.payload.values
      else if builtins.elem type.name ["nullOr" "listOf" "attrsOf"]
      then lib.types.${type.name} type.nestedTypes.elemType
      else if type.name == "submodule"
      then lib.types.submodule {}
      else null;
    position = builtins.unsafeGetAttrPos "check" type;
    basePosition =
      if base == null
      then null
      else builtins.unsafeGetAttrPos "check" base;
    unrefined =
      base
      != null
      && position != null
      && basePosition != null
      && position == basePosition;
    label =
      if path == []
      then type.name
      else lib.showOption path;
  in
    if base != null && !unrefined
    then throw "runtimeValues: unsupported refinement at ${label}; provide an explicit runtime schema descriptor"
    else if builtins.elem type.name ["str" "bool" "int" "float"]
    then {kind = type.name;}
    else if type.name == "enum"
    then {
      kind = "enum";
      values = type.functor.payload.values;
    }
    else if builtins.elem type.name ["nullOr" "listOf" "attrsOf"]
    then {
      kind = type.name;
      element = schemaForAt path type.nestedTypes.elemType;
    }
    else if type.name == "submodule"
    then {
      kind = "record";
      fields = lib.mapAttrs (name: option: schemaForAt (path ++ [name]) option.type) (builtins.removeAttrs (type.getSubOptions []) ["_module"]);
    }
    else throw "runtimeValues: unsupported runtime schema at ${label} for ${type.name}; provide an explicit runtime schema descriptor";
  schemaFor = schemaForAt [];
in {inherit schemaFor schemaForAt;}
