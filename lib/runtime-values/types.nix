{
  lib,
  classify,
  validReference,
}: let
  inherit (lib) types;
  reference = types.mkOptionType {
    name = "runtime reference";
    description = "runtime reference";
    check = validReference;
    merge = lib.options.mergeEqualOption;
  };
  stamp = secret: value:
    value
    // {
      _runtime = value._runtime // {secret = secret || value._runtime.secret;};
    };
  withReferences = {
    type,
    secret ? false,
  }: let
    supported = type == types.bool || type == types.str;
    label = type.name or "unknown";
    referenceType = reference // {merge = loc: defs: stamp secret (reference.merge loc defs);};
    secretType =
      referenceType
      // {
        check = _: true;
        merge = loc: defs:
          if lib.all (def: validReference def.value) defs
          then referenceType.merge loc defs
          else throw "runtimeValues: ${lib.showOption loc}: secret literals are forbidden";
      };
  in
    if !supported
    then throw "runtimeValues: unsupported reference type ${label}; expected str or bool"
    else
      (
        if secret
        then secretType
        else types.either type referenceType
      )
      // {
        runtimeValue = {inherit secret;};
      };
  keyAwareMap = {
    type,
    path,
    secretContainer ? false,
  }: let
    nullable = type.name == "nullOr" && type.nestedTypes.elemType == types.str;
    supported = type == types.str || nullable;
    containerSecret = secretContainer || classify {inherit path;};
    entry = types.mkOptionType {
      name = "string or runtime reference";
      description = "string or runtime reference";
      check = _: true;
      merge = loc: defs:
        (withReferences {
          type = types.str;
          secret = classify {
            path = path ++ [(lib.last loc)];
            secretContainer = containerSecret;
          };
        }).merge
        loc
        defs;
    };
    entryType =
      if nullable
      then types.nullOr entry
      else entry;
    base = types.attrsOf entryType;
  in
    if !supported
    then throw "runtimeValues: unsupported map type ${type.name or "unknown"}; expected str or nullOr str"
    else
      base
      // {
        runtimeValueMap = {
          secretContainer = containerSecret;
        };
      };
in {
  inherit keyAwareMap withReferences;
}
