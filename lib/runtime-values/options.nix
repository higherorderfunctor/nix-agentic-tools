{
  lib,
  types,
  classify,
  schemaForAt,
}: let
  classifyPath = path: secretContainer:
    (lib.foldl' (state: name: let
        here = state.path ++ [name];
      in {
        path = here;
        secret =
          classify {
            path = here;
            secretContainer = state.secret;
          }
          == "secret";
      }) {
        path = [];
        secret = secretContainer;
      }
      path).secret;
  # Both lifting and auditing use this traversal. Classification is carried
  # through namespaces and each collection layer before a leaf is handled.
  traverseType = {
    type,
    path,
    hints ? {},
    secretContainer ? false,
    handlers,
  }: let
    secret = (classifyPath path secretContainer) || classify {inherit path hints secretContainer;} == "secret";
    child = childPath: element:
      traverseType {
        type = element;
        path = childPath;
        secretContainer = secret;
        inherit handlers;
      };
  in
    if type.name == "nullOr"
    then
      handlers.nullOr {
        inherit type path secret;
        element = child path type.nestedTypes.elemType;
      }
    else if type.name == "listOf"
    then
      handlers.listOf {
        inherit type path secret;
        element = child path type.nestedTypes.elemType;
      }
    else if type.name == "attrsOf"
    then
      handlers.attrsOf {
        inherit type path hints secret;
        element = key: child (path ++ [key]) type.nestedTypes.elemType;
      }
    else if type.name == "submodule"
    then handlers.submodule {inherit type path secret;}
    else handlers.leaf {inherit type path secret;};
  traverseOptions = {
    node,
    path,
    secretContainer,
    handlers,
  }:
    if lib.isOption node
    then
      handlers.option {
        option = node;
        inherit path secretContainer;
      }
    else if builtins.isAttrs node
    then let
      inherited = classifyPath path secretContainer;
    in
      handlers.namespace (lib.mapAttrs (name: child:
        if name == "_module"
        then handlers.module child
        else
          traverseOptions {
            node = child;
            path = path ++ [name];
            secretContainer = inherited;
            inherit handlers;
          })
      node)
    else handlers.other node;
  liftType = {
    type,
    path,
    hints ? {},
    secretContainer ? false,
    schema ? null,
  }: let
    rejectDynamic = {
      type,
      path,
      ...
    }:
      builtins.deepSeq (schemaForAt path type) (throw "runtimeValues: dynamic type unexpectedly accepted at ${lib.showOption path}");
  in
    traverseType {
      inherit type path hints secretContainer;
      handlers = {
        nullOr = rejectDynamic;
        listOf = rejectDynamic;
        attrsOf = rejectDynamic;
        submodule = rejectDynamic;
        leaf = {
          type,
          path,
          secret,
        }:
          if builtins.elem type.name ["runtimeValue" "runtimeValueMap"]
          then type
          else
            builtins.deepSeq (schemaForAt path type) (types.withReferences {
              inherit type path secret;
              schema =
                if schema != null
                then schema
                else schemaForAt path type;
            });
      };
    };
  # Normalized schema records have `fields`; leaves have a Nix `type`.
  # Descriptions, defaults and upstream classifier hints are optional metadata.
  fromSchema = {
    schema,
    prefix ? [],
    overrides ? {},
  }: let
    generate = path: secretContainer: fields:
      lib.mapAttrs (name: field: let
        here = path ++ [name];
        secret =
          classify {
            path = here;
            hints = field.hints or {};
            inherit secretContainer;
          }
          == "secret";
        hasFields = field ? fields;
        valid = hasFields != (field ? type);
        default =
          field.default or (
            if hasFields
            then {}
            else null
          );
        base =
          if hasFields
          then lib.types.submodule {options = generate here secret field.fields;}
          else
            liftType {
              inherit (field) type;
              inherit secretContainer;
              path = here;
              hints = field.hints or {};
              schema = field.schema or null;
            };
      in
        if !valid
        then throw "${lib.showOption here}: normalized schema requires exactly one of fields or type"
        else
          (lib.mkOption {
            type =
              if default == null
              then lib.types.nullOr base
              else base;
            inherit default;
            description = field.description or "Runtime-configurable value.";
          })
          // {runtimeValueHints = field.hints or {};})
      fields;
  in {options = lib.recursiveUpdate (generate prefix false schema.fields) overrides;};
  liftOptions = {
    options,
    prefix ? [],
    hints ? {},
    secretContainer ? false,
  }:
    traverseOptions {
      node = options;
      path = prefix;
      inherit secretContainer;
      handlers = {
        namespace = value: value;
        module = value: value;
        other = value: value;
        option = {
          option,
          path,
          secretContainer,
        }:
          option
          // {
            type = liftType {
              inherit (option) type;
              inherit path secretContainer;
              hints = hints.${lib.last path} or {};
            };
          };
      };
    };
  checkOptions = {
    options,
    roots,
  }: let
    auditType = path: secretContainer: hints: type:
      traverseType {
        inherit type path secretContainer hints;
        handlers = {
          nullOr = {element, ...}: element;
          listOf = {element, ...}: element;
          attrsOf = {path, ...}: ["${lib.showOption path}: open map lacks key-aware classification"];
          submodule = {
            type,
            path,
            secret,
          }: let
            nested = type.getSubOptions path;
            freeform = type.nestedTypes.freeformType or null;
          in
            (
              if nested == {}
              then []
              else visit path secret nested
            )
            ++ (
              if freeform == null
              then []
              else auditType path secret {} freeform
            );
          leaf = {
            type,
            path,
            secret,
          }:
            if type.name == "runtimeValue"
            then lib.optional (secret && !(type.functor.payload.secret or false)) (lib.showOption path)
            else if type.name == "runtimeValueMap"
            then let
              context = type.functor.payload;
            in
              lib.optional (secret && !(context.secretContainer || (context.hints.keyring or false) || (context.hints.secret or false))) (lib.showOption path)
            else lib.optional secret (lib.showOption path);
        };
      };
    visit = path: secretContainer: node:
      traverseOptions {
        inherit node path secretContainer;
        handlers = {
          namespace = value: lib.concatLists (builtins.attrValues value);
          module = _: [];
          other = _: [];
          option = {
            option,
            path,
            secretContainer,
          }:
            auditType path secretContainer (option.runtimeValueHints or {}) option.type;
        };
      };
  in
    lib.concatMap (path: visit path false (lib.attrByPath path {} options)) roots;
in {inherit checkOptions fromSchema liftOptions;}
