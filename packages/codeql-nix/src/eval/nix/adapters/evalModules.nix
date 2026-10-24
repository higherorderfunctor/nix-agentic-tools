{
  lib,
  library ? null,
  moduleBindings ? [],
  modules,
  moduleArguments,
  specialArguments,
}: let
  effectiveLib =
    if library == null
    then lib
    else import ((builtins.fetchTree (library // {type = "path";})).outPath + "/lib");
  # Reuse pinned normalization; sanitize only metadata-demanded labels lazily.
  sanitize = value:
    if builtins.isAttrs value
    then
      effectiveLib.mapAttrs (name: child:
        if value._type or "" == "definition" && name == "file"
        then builtins.unsafeDiscardStringContext child
        else sanitize child)
      value
    else if builtins.isList value
    then map sanitize value
    else value;
  wrap = parent: key: module: args: let
    isPath = builtins.isPath module || builtins.isString module;
    loaded =
      if isPath
      then import module
      else module;
    effectiveKey =
      if isPath
      then toString module
      else key;
    applied = effectiveLib.applyModuleArgsIfFunction effectiveKey loaded args;
    file =
      if builtins.isPath module
      then builtins.appendContext (toString module) (builtins.getContext "${module}")
      else if isPath
      then module
      else parent;
    normalized = effectiveLib.unifyModuleSyntax file effectiveKey applied;
    label =
      if applied ? _file
      then builtins.unsafeDiscardStringContext normalized._file
      else normalized._file;
  in
    normalized
    // {
      _file = label;
      config = sanitize normalized.config;
      imports = effectiveLib.imap0 (i: child: wrap label "${normalized.key}:anon-${toString i}" child) normalized.imports;
    };
  evaluated = effectiveLib.evalModules {
    modules = map (module: wrap "" (toString module) module) modules ++ [{_module.args = moduleArguments;}];
    specialArgs = specialArguments;
  };
in
  evaluated
  // {
    nixqlLibrary = effectiveLib;
    # Root file invocations are covered; imported/computed functions stay unknown.
    nixqlModuleBindings = effectiveLib.unique (map (binding: {inherit (binding) functionAnchor formalAnchor;}) (effectiveLib.concatMap (module:
      effectiveLib.optionals (library
        != null
        && !(specialArguments ? lib)
        && (builtins.isPath module || builtins.isString module)
        && builtins.isFunction (import module))
      (builtins.filter (binding: binding.path == toString module) moduleBindings))
    modules));
  }
