{lib}: let
  classification = import ./classify.nix {inherit lib;};
  schemas = import ./schema.nix {inherit lib;};
  types = import ./types.nix {
    inherit (schemas) schemaFor;
    inherit lib;
    inherit (classification) classify;
  };
  constructor = kind: {
    path,
    decode ? "string",
    newline ? "strip-final-lf",
    prefix ? "",
    suffix ? "",
    secret ? false,
  }: {
    _runtime = {
      inherit decode newline prefix suffix secret;
      source.${kind} = path;
    };
  };
  recognize = value:
    if !types.isReference value
    then null
    else let
      evaluated = lib.evalModules {
        modules = [
          {
            options.value = lib.mkOption {type = types.reference;};
            config.value = value;
          }
        ];
      };
    in
      builtins.deepSeq evaluated.config.value evaluated.config.value._runtime;
  walk = {
    value,
    schema ? null,
    path ? [],
  }: let
    ref = recognize value;
    children =
      if builtins.isAttrs value
      then
        lib.mapAttrs (name: child:
          walk {
            value = child;
            path = path ++ [name];
            schema =
              if schema != null && schema ? fields
              then schema.fields.${name} or null
              else if schema != null
              then schema.element or null
              else null;
          })
        value
      else {};
    items =
      if builtins.isList value
      then
        lib.imap0 (index: child:
          walk {
            value = child;
            path = path ++ [toString index];
            schema =
              if schema != null
              then schema.element or null
              else null;
          })
        value
      else [];
  in
    if ref != null
    then {
      publicValue = null;
      bindings = [
        {
          inherit path;
          schema =
            if schema == null
            then ref.validation
            else schema;
          reference = ref;
        }
      ];
    }
    else if builtins.isAttrs value
    then {
      publicValue = lib.mapAttrs (_: child: child.publicValue) children;
      bindings = lib.concatMap (child: child.bindings) (builtins.attrValues children);
    }
    else if builtins.isList value
    then {
      publicValue = map (child: child.publicValue) items;
      bindings = lib.concatMap (child: child.bindings) items;
    }
    else {
      publicValue = value;
      bindings = [];
    };
  options = import ./options.nix {
    inherit lib types;
    inherit (classification) classify;
    inherit (schemas) schemaForAt;
  };
in
  classification
  // schemas
  // types
  // options
  // (import ./materialize.nix {
    inherit lib recognize;
    inherit (classification) classify;
  })
  // {
    inherit recognize walk;
    file = constructor "file";
    helper = constructor "helper";
  }
