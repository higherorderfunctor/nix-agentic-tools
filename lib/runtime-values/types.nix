{
  lib,
  classify,
}: let
  inherit (lib) mkOption types;
  isReference = value: builtins.isAttrs value && value ? _runtime;
  referenceBase = types.submodule {
    options._runtime = mkOption {
      type = types.submodule {
        options = {
          secret = mkOption {
            type = types.bool;
            default = false;
            internal = true;
          };
          source = mkOption {
            type = types.attrTag {
              file = mkOption {type = types.str;};
              helper = mkOption {type = types.str;};
            };
          };
        };
      };
    };
  };
  reference = referenceBase // {check = value: isReference value && referenceBase.check value;};
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
    literal =
      (types.addCheck type (value: !isReference value))
      // {
        merge = loc: defs: let
          merged = type.merge loc defs;
        in
          if secret && merged != null
          then throw "runtimeValues: ${lib.showOption loc}: secret literals are forbidden"
          else merged;
      };
    referenceType = reference // {merge = loc: defs: stamp secret (reference.merge loc defs);};
  in
    if !supported
    then throw "runtimeValues: unsupported reference type ${label}; expected str or bool"
    else
      (types.either literal referenceType)
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
    entry = withReferences {type = types.str;};
    entryType =
      if nullable
      then types.nullOr entry
      else entry;
    base = types.attrsOf entryType;
    containerSecret = secretContainer || classify {inherit path;};
    validate = loc: key: value: let
      secret = classify {
        path = path ++ [key];
        secretContainer = containerSecret;
      };
    in
      if value == null
      then null
      else if isReference value
      then stamp secret value
      else if secret
      then throw "runtimeValues: ${lib.showOption (loc ++ [key])}: secret literals are forbidden"
      else value;
  in
    if !supported
    then throw "runtimeValues: unsupported map type ${type.name or "unknown"}; expected str or nullOr str"
    else
      base
      // {
        merge = loc: defs: lib.mapAttrs (validate loc) (base.merge loc defs);
        runtimeValueMap = {
          secretContainer = containerSecret;
        };
      };
in {
  inherit isReference keyAwareMap reference withReferences;
}
