{lib}: let
  schemaFor = type:
    if builtins.elem type.name ["str" "bool" "int" "float"]
    then {kind = type.name;}
    else if type.name == "enum"
    then {
      kind = "enum";
      values = type.functor.payload.values;
    }
    else if builtins.elem type.name ["nullOr" "listOf" "attrsOf"]
    then {
      kind = type.name;
      element = schemaFor type.nestedTypes.elemType;
    }
    else if type.name == "submodule"
    then {
      kind = "record";
      fields = lib.mapAttrs (_: option: schemaFor option.type) (builtins.removeAttrs (type.getSubOptions []) ["_module"]);
    }
    else throw "runtimeValues: unsupported runtime schema for ${type.name}; provide an explicit scalar schema descriptor";
in {inherit schemaFor;}
