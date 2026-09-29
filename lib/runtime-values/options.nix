{
  lib,
  types,
  classify,
  classifyPath,
  originalCheck,
  originalMerge,
}: let
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
    # A container retains its original literal branch and check. Recursive
    # references use the constructor's module merge machinery only when no
    # opaque outer check or merge has been attached.
    container = original: lifted: let
      hasReference = value:
        types.isReference value
        || (builtins.isList value && lib.any hasReference value)
        || (builtins.isAttrs value && lib.any hasReference (builtins.attrValues value));
      safe =
        if original ? runtimeValueContainer
        then
          original.runtimeValueContainer.safe
          && builtins.unsafeGetAttrPos "check" original == original.runtimeValueContainer.checkPosition
          && builtins.unsafeGetAttrPos "merge" original == original.runtimeValueContainer.mergePosition
        else originalCheck original && originalMerge original;
      wrapped =
        lifted
        // {
          runtimeValueContainer = {
            inherit safe;
            checkPosition = builtins.unsafeGetAttrPos "check" wrapped;
            mergePosition = builtins.unsafeGetAttrPos "merge" wrapped;
          };
          substSubModules = modules: container original (lifted.substSubModules modules);
          check = value:
            if types.isReference value
            then throw "runtimeValues: ${lib.showOption path}: whole-container references require decode=json, which is not supported in this pilot"
            else if hasReference value && !safe
            then throw "runtimeValues: ${lib.showOption path}: opaque container predicate cannot validate references"
            else if hasReference value
            then lifted.check value
            else original.check value;
          merge = loc: defs:
            if !safe
            then (lifted.runtimeValuePostMerge or (_: v: v)) loc (original.merge loc defs)
            else lifted.merge loc defs;
        };
    in
      wrapped;
    liftModule = secret: module: args: let
      loaded =
        if builtins.isPath module || builtins.isString module
        then import module
        else module;
      applied = lib.modules.applyModuleArgsIfFunction "runtime value submodule" loaded args;
      normalized = lib.modules.unifyModuleSyntax "<runtime value submodule>" "runtime value submodule" applied;
    in {
      imports = map (child: liftModule secret child) normalized.imports;
      options = liftOptions {
        inherit (normalized) options;
        prefix = path;
        secretContainer = secret;
      };
      inherit (normalized) _class _file disabledModules;
      config = let
        transform = value:
          if value._type or "" == "merge"
          then value // {contents = map transform value.contents;}
          else if builtins.elem (value._type or "") ["if" "override"]
          then value // {content = transform value.content;}
          else
            value
            // lib.optionalAttrs (value._module.freeformType or null != null) {
              _module =
                value._module
                // {
                  freeformType = liftType {
                    type = value._module.freeformType;
                    inherit path;
                    secretContainer = secret;
                  };
                };
            };
      in
        transform normalized.config;
    };
  in
    traverseType {
      inherit type path hints secretContainer;
      handlers = {
        nullOr = {
          type,
          element,
          secret,
          ...
        }:
          if builtins.elem type.nestedTypes.elemType.name ["attrsOf" "listOf" "submodule" "nullOr"]
          then
            container type ((lib.types.nullOr element)
              // {
                runtimeValuePostMerge = loc: value:
                  if value == null
                  then null
                  else (element.runtimeValuePostMerge or (_: v: v)) loc value;
              })
          else types.withReferences {inherit type path secret schema;};
        listOf = {
          type,
          element,
          ...
        }:
          container type ((lib.types.listOf element)
            // {
              runtimeValuePostMerge = loc: value: map ((element.runtimeValuePostMerge or (_: v: v)) loc) value;
            });
        attrsOf = {
          type,
          element,
          secret,
          ...
        }:
          container type (types.keyAwareMap {
            type = type.nestedTypes.elemType;
            inherit path hints;
            secretContainer = secret;
            typeFor = element;
            original = type;
          });
        submodule = {
          type,
          secret,
          ...
        }: let
          lifted = type.substSubModules (map (liftModule secret) type.getSubModules);
        in
          container type (lifted
            // {
              runtimeValuePostMerge = loc: value: let
                options = lifted.getSubOptions loc;
                visit = context: declarations: values:
                  lib.mapAttrs (name: v:
                    if declarations ? ${name}
                    then let
                      option = declarations.${name};
                    in
                      if lib.isOption option
                      then (option.type.runtimeValuePostMerge or (_: x: x)) (context ++ [name]) v
                      else visit (context ++ [name]) option v
                    else v)
                  values;
              in
                visit loc options value;
            });
        leaf = {
          type,
          secret,
          ...
        }:
          if type.name == "runtimeValueMap"
          then let
            rebuilt = types.keyAwareMap {
              inherit (type.functor.payload) type;
              inherit path hints;
              secretContainer = secret || type.functor.payload.secretContainer;
              typeFor =
                if type.functor.payload.typeFor or null == null
                then null
                else
                  key:
                    liftType {
                      type = type.functor.payload.typeFor key;
                      path = path ++ [key];
                      secretContainer = secret || type.functor.payload.secretContainer;
                    };
            };
          in
            if type ? runtimeValueContainer
            then container type rebuilt
            else rebuilt
          else types.withReferences {inherit type path secret schema;};
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
