{lib}: let
  # addCheck and direct check overrides replace the check attribute. Inspect its
  # declaration provenance, not function equality (Nix closures are not equal).
  # An unrecognized check stays usable for literals, but needs an explicit
  # descriptor before a reference can enter the runtime reader.
  originalCheck = type:
    builtins.unsafeGetAttrPos "check" type == builtins.unsafeGetAttrPos "check" lib.types.str;
  originalMerge = type:
    builtins.unsafeGetAttrPos "merge" type == builtins.unsafeGetAttrPos "merge" lib.types.str;
  schemaForAt = path: type: let
    fail = throw "runtimeValues: opaque runtime predicate at ${
      if path == []
      then type.name
      else lib.showOption path
    } for ${type.name}; supply an explicit runtime schema";
    constructor = type.functor.name or type.name;
  in
    if !originalCheck type
    then fail
    else if builtins.elem type.name ["bool" "float" "int" "str"] && type == lib.types.${type.name}
    then {kind = type.name;}
    else if constructor == "enum" && type.functor.payload ? values && lib.all builtins.isString type.functor.payload.values
    then {
      kind = "enum";
      inherit (type.functor.payload) values;
    }
    else if constructor == "strMatching" && type.functor.payload ? pattern
    then {
      kind = "strMatching";
      inherit (type.functor.payload) pattern;
    }
    else if type.name == "nullOr"
    then schemaForAt path type.nestedTypes.elemType
    else fail;
  schemaFor = schemaForAt [];
in {inherit originalCheck originalMerge schemaFor schemaForAt;}
