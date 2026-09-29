{
  lib,
  classify,
  schemaForAt,
}: let
  inherit (lib) mkOption types;
  reference = types.submodule {
    options._runtime = mkOption {
      type = types.submodule {
        options = {
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
                  type = types.enum ["str" "bool" "int" "float" "enum"];
                  default = "str";
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
    schema ? schemaForAt path type,
  }: let
    # A supplied descriptor cannot prove that an arbitrary Nix predicate is
    # available to the runtime reader. Validate the original type regardless.
    checked = schemaForAt path type;
    label =
      if path == []
      then type.name
      else lib.showOption path;
  in
    builtins.deepSeq checked (
      if schema != checked
      then throw "runtimeValues: schema mismatch at ${label} for ${type.name}; runtime references cannot reproduce its constraints"
      else
        lib.mkOptionType {
          name = "runtimeValue";
          description =
            if secret
            then "runtime reference (secret literals are forbidden)"
            else "${type.description} or runtime reference";
          check = value:
            if isReference value
            then
              reference.check value
              && (
                checked.kind
                == "str"
                || ((value._runtime.prefix or "") == "" && (value._runtime.suffix or "") == "")
              )
            else type.check value && (!secret || value == null);
          merge = loc: defs:
            if builtins.all (def: isReference def.value) defs
            then let
              merged = reference.merge loc defs;
            in
              merged
              // {
                _runtime =
                  merged._runtime
                  // {
                    secret = secret || merged._runtime.secret;
                    validation = checked;
                  };
              }
            else if builtins.any (def: isReference def.value) defs
            then throw "${lib.showOption loc}: cannot merge a runtime reference with a literal"
            else type.merge loc defs;
          inherit (type) getSubModules getSubOptions;
          nestedTypes = {
            literal = type;
            inherit reference;
          };
          functor = {
            name = "runtimeValue";
            payload = {inherit secret;};
          };
        }
    );
  keyAwareMap = {
    type,
    path ? [],
    hints ? {},
    secretContainer ? false,
    typeFor ? null,
  }: let
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
              inherit hints secretContainer;
            }
            == "secret";
        };
    base = types.attrsOf type;
  in
    lib.mkOptionType {
      name = "runtimeValueMap";
      description = "key-classified map of ${type.description} or runtime references";
      check = value: builtins.isAttrs value && !isReference value && lib.all (key: (entryType key).check value.${key}) (builtins.attrNames value);
      merge = loc: defs:
        lib.mapAttrs (key: entries: (lib.mergeDefinitions (loc ++ [key]) (entryType key) entries).mergedValue) (lib.zipAttrsWith (_: entries: entries) (map (def:
          lib.mapAttrs (_: value: {
            inherit (def) file;
            inherit value;
          })
          def.value)
        defs));
      inherit (base) emptyValue;
      functor = {
        name = "runtimeValueMap";
        payload = {inherit path hints secretContainer;};
      };
    };
in {inherit isReference keyAwareMap reference withReferences;}
