{
  lib,
  classify,
  classifyPath,
  schemaForAt,
}: let
  inherit (lib) mkOption types;
  reference = types.submodule {
    options._runtime = mkOption {
      type = types.submodule {
        options = {
          classification = mkOption {
            type = types.enum ["sensitive" "secret"];
            default = "sensitive";
            internal = true;
          };
          decode = mkOption {
            type = types.enum ["string"];
            default = "string";
            description = "Runtime decoding; only string is supported in this pilot.";
          };
          newline = mkOption {
            type = types.enum ["strip-final-lf" "preserve"];
            default = "strip-final-lf";
          };
          prefix = mkOption {
            type = types.str;
            default = "";
          };
          secret = mkOption {
            type = types.bool;
            default = false;
          };
          source = mkOption {
            type = types.attrTag {
              file = mkOption {type = types.str;};
              helper = mkOption {type = types.str;};
            };
          };
          validation = mkOption {
            type = types.submodule {
              options = {
                kind = mkOption {
                  type = types.enum ["str" "bool" "int" "float" "enum" "strMatching"];
                  default = "str";
                };
                pattern = mkOption {
                  type = types.str;
                  default = "";
                };
                values = mkOption {
                  type = types.listOf types.str;
                  default = [];
                };
              };
            };
            default = {};
            internal = true;
          };
          suffix = mkOption {
            type = types.str;
            default = "";
          };
        };
      };
    };
  };
  isReference = value: builtins.isAttrs value && value ? _runtime;
  withReferences = {
    type,
    path ? [],
    secret ? false,
    schema ? null,
  }: let
    existing = type.name == "runtimeValue";
    original =
      if existing
      then type.nestedTypes.literal
      else type;
    tainted = secret || (existing && type.functor.payload.secret);
    explicitSchema =
      if schema != null
      then schema
      else if existing
      then type.functor.payload.explicitSchema or null
      else null;
    descriptor =
      if explicitSchema != null
      then let
        derived = builtins.tryEval (builtins.deepSeq (schemaForAt path original) (schemaForAt path original));
      in
        if derived.success && derived.value != explicitSchema
        then throw "runtimeValues: explicit schema disagrees with the declared type at ${lib.showOption path}"
        else explicitSchema
      else if existing
      then type.functor.payload.schema
      else schemaForAt path original;
    structured = builtins.elem original.name ["attrsOf" "listOf" "submodule"];
    label =
      if path == []
      then original.name
      else lib.showOption path;
    literal = types.addCheck original (value: !isReference value && (!tainted || value == null));
    refType =
      reference
      // {
        check = value:
          if !isReference value
          then false
          else if structured
          then throw "runtimeValues: ${label}: whole-container references require decode=json, which is not supported in this pilot"
          else builtins.deepSeq descriptor (reference.check value && (descriptor.kind == "str" || ((value._runtime.prefix or "") == "" && (value._runtime.suffix or "") == "")));
        merge = loc: defs: let
          merged = reference.merge loc defs;
        in
          merged
          // {
            _runtime =
              merged._runtime
              // {
                classification =
                  if tainted || merged._runtime.classification == "secret"
                  then "secret"
                  else "sensitive";
                secret = tainted || merged._runtime.secret || merged._runtime.classification == "secret";
                validation = descriptor;
              };
          };
      };
    union = types.either literal refType;
  in
    union
    // {
      runtimeValuePostMerge = loc: value:
      # The original merger already checked its input definitions. Its result
      # need not satisfy an input-only predicate again: classify, do not merge
      # or validate the original type a second time.
        if !isReference value
        then
          if tainted && value != null
          then throw "runtimeValues: ${lib.showOption loc}: secret literals are forbidden"
          else value
        else
          value
          // {
            _runtime =
              value._runtime
              // {
                classification =
                  if tainted || value._runtime.classification == "secret"
                  then "secret"
                  else "sensitive";
                secret = tainted || value._runtime.secret || value._runtime.classification == "secret";
              };
          };
      name = "runtimeValue";
      inherit (original) emptyValue;
      # Keep the complete original object: literal checks/merges are never rebuilt.
      nestedTypes = {
        literal = original;
        reference = refType;
      };
      functor = {
        name = "runtimeValue";
        payload = {
          inherit explicitSchema original path;
          secret = tainted;
          schema = descriptor;
        };
      };
      typeMerge = other:
        if other.name != "runtimeValue"
        then null
        else let
          merged = original.typeMerge other.payload.original.functor;
          otherSchema = other.payload.explicitSchema or null;
        in
          if merged == null || (explicitSchema != null && otherSchema != null && explicitSchema != otherSchema)
          then null
          else
            withReferences {
              type = merged;
              inherit path;
              secret = tainted || other.payload.secret;
              schema =
                if explicitSchema != null
                then explicitSchema
                else otherSchema;
            };
    };
  keyAwareMap = {
    type,
    path ? [],
    hints ? {},
    secretContainer ? false,
    typeFor ? null,
    original ? null,
  }: let
    effectiveSecret = classifyPath path secretContainer || classify {inherit path hints;} == "secret";
    entryType = key:
      if typeFor != null
      then typeFor key
      else
        withReferences {
          inherit type;
          path = path ++ [key];
          secret =
            classify {
              path = path ++ [key];
              inherit hints;
              secretContainer = effectiveSecret;
            }
            == "secret";
        };
    # The ordinary attrsOf merger owns mkIf, priorities and omitted entries.
    # Only the effective value is classified; raw definitions are never scanned.
    base = types.attrsOf (
      if typeFor == null
      then withReferences {inherit type;}
      else typeFor "<name>"
    );
    validate = loc: key: value: let
      target = entryType key;
    in
      if target ? runtimeValuePostMerge
      then target.runtimeValuePostMerge (loc ++ [key]) value
      else if target.check value
      then value
      else throw "runtimeValues: ${lib.showOption (loc ++ [key])}: value violates the classified declaration";
    postMerge = loc: value: lib.mapAttrs (validate loc) value;
  in
    base
    // {
      name = "runtimeValueMap";
      check = value: builtins.isAttrs value && !isReference value;
      merge = loc: defs: postMerge loc (base.merge loc defs);
      runtimeValuePostMerge = postMerge;
      functor = {
        name = "runtimeValueMap";
        payload = {
          inherit type path hints original typeFor;
          secretContainer = effectiveSecret;
        };
      };
      typeMerge = other:
        if other.name != "runtimeValueMap" || path != other.payload.path || hints != other.payload.hints
        then null
        else let
          merged = type.typeMerge other.payload.type.functor;
          mergedFor =
            if typeFor == null && other.payload.typeFor == null
            then null
            else if typeFor != null && other.payload.typeFor != null
            then key: (typeFor key).typeMerge (other.payload.typeFor key).functor
            else null;
        in
          if merged == null || ((typeFor == null) != (other.payload.typeFor == null)) || (mergedFor != null && mergedFor "<name>" == null)
          then null
          else
            keyAwareMap {
              type = merged;
              inherit path hints;
              secretContainer = effectiveSecret || other.payload.secretContainer;
              typeFor = mergedFor;
            };
    };
in {inherit isReference keyAwareMap reference withReferences;}
