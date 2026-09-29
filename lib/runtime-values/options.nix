{
  lib,
  types,
  classify,
  schemaForAt,
}: let
  liftType = {
    type,
    path,
    hints ? {},
    secretContainer ? false,
    schema ? null,
  }: let
    secret = classify {inherit path hints secretContainer;} == "secret";
    child = element:
      liftType {
        type = element;
        inherit path;
        secretContainer = secret;
      };
  in
    if type.name == "nullOr"
    then lib.types.nullOr (child type.nestedTypes.elemType)
    else if type.name == "listOf"
    then lib.types.listOf (child type.nestedTypes.elemType)
    else if type.name == "attrsOf"
    then
      types.keyAwareMap {
        type = type.nestedTypes.elemType;
        inherit path hints;
        secretContainer = secret;
        typeFor = key:
          liftType {
            type = type.nestedTypes.elemType;
            path = path ++ [key];
            secretContainer = secret;
          };
      }
    else if type.name == "submodule"
    then
      type.substSubModules (map (liftModule {
          inherit path;
          secretContainer = secret;
        })
        type.getSubModules)
    else if builtins.elem type.name ["runtimeValue" "runtimeValueMap"]
    then type
    else
      types.withReferences {
        inherit type secret;
        schema =
          if schema != null
          then schema
          else schemaForAt path type;
      };
  liftModule = {
    path,
    secretContainer,
  }: module: args @ {config, ...}: let
    imported =
      if builtins.isPath module || builtins.isString module
      then import module
      else module;
    resolved =
      if builtins.isFunction imported
      then imported (args // lib.mapAttrs (name: _: args.${name} or config._module.args.${name}) (builtins.functionArgs imported))
      else imported;
  in
    resolved
    // lib.optionalAttrs (resolved ? options) {
      options = liftOptions {
        inherit (resolved) options;
        prefix = path;
        inherit secretContainer;
      };
    }
    // lib.optionalAttrs (resolved ? imports) {imports = map (liftModule {inherit path secretContainer;}) resolved.imports;}
    // lib.optionalAttrs (resolved ? freeformType) {
      freeformType = liftType {
        type = resolved.freeformType;
        inherit path secretContainer;
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
    lib.mapAttrs (name: option: let
      path = prefix ++ [name];
    in
      if name == "_module"
      then option
      else if lib.isOption option
      then
        option
        // {
          type = liftType {
            inherit (option) type;
            inherit path secretContainer;
            hints = hints.${name} or {};
          };
        }
      else
        liftOptions {
          options = option;
          prefix = path;
          inherit hints secretContainer;
        })
    options;
  checkOptions = {
    options,
    roots,
  }: let
    checkType = path: secretContainer: hints: type: let
      secret = classify {inherit path secretContainer hints;} == "secret";
      nested = type.getSubOptions path;
      guarded = builtins.elem type.name ["runtimeValue" "runtimeValueMap"];
      mapGuarded =
        if type.name == "runtimeValueMap"
        then let
          context = type.functor.payload;
        in
          context.secretContainer
          || (context.hints.keyring or false)
          || (context.hints.secret or false)
        else false;
    in
      if guarded
      then
        lib.optional (
          secret
          && (
            (type.name == "runtimeValue" && !(type.functor.payload.secret or false))
            || (type.name == "runtimeValueMap" && !mapGuarded)
          )
        ) (lib.showOption path)
      else if builtins.elem type.name ["nullOr" "listOf"]
      then checkType path secret hints type.nestedTypes.elemType
      else if type.name == "attrsOf"
      then ["${lib.showOption path}: open map lacks key-aware classification"]
      else
        lib.optional (secret && nested == {}) (lib.showOption path)
        ++ (
          if nested == {}
          then []
          else visit path secret nested
        )
        ++ lib.optional (type.nestedTypes ? freeformType && type.nestedTypes.freeformType.name != "runtimeValueMap") "${lib.showOption path}: freeform map lacks key-aware classification";
    visit = path: secretContainer: node:
      if lib.isOption node
      then checkType path secretContainer (node.runtimeValueHints or {}) node.type
      else if builtins.isAttrs node
      then
        lib.concatLists (lib.mapAttrsToList (name: child:
          if name == "_module"
          then []
          else visit (path ++ [name]) secretContainer child)
        node)
      else [];
  in
    lib.concatMap (path: visit path false (lib.attrByPath path {} options)) roots;
in {inherit checkOptions fromSchema liftOptions;}
