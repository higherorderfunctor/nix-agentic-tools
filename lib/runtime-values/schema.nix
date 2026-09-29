{lib}: let
  # Equality is sound only for these singleton option types. Dynamic types
  # contain functions, so rebuilding one cannot prove that its predicates or
  # merge behavior are identical to the original.
  scalarNames = ["bool" "float" "int" "str"];
  schemaForAt = path: type:
    if builtins.elem type.name scalarNames && type == lib.types.${type.name}
    then {kind = type.name;}
    else
      throw "runtimeValues: unsupported runtime type at ${
        if path == []
        then type.name
        else lib.showOption path
      } for ${type.name}; cannot preserve its checks and merge behavior";
  schemaFor = schemaForAt [];
in {inherit schemaFor schemaForAt;}
