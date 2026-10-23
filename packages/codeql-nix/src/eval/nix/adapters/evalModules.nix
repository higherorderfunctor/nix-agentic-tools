{
  lib,
  modules,
  moduleArguments,
  specialArguments,
}: let
  # Reuse pinned normalization; sanitize only metadata-demanded labels lazily.
  sanitize = value:
    if builtins.isAttrs value
    then
      lib.mapAttrs (name: child:
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
    applied = lib.applyModuleArgsIfFunction effectiveKey loaded args;
    file =
      if isPath
      then toString module
      else parent;
    normalized = lib.unifyModuleSyntax file effectiveKey applied;
    label =
      if applied ? _file
      then builtins.unsafeDiscardStringContext normalized._file
      else normalized._file;
  in
    normalized
    // {
      _file = label;
      config = sanitize normalized.config;
      imports = lib.imap0 (i: child: wrap label "${normalized.key}:anon-${toString i}" child) normalized.imports;
    };
in
  lib.evalModules {
    modules = map (module: wrap "" (toString module) module) modules ++ [{_module.args = moduleArguments;}];
    specialArgs = specialArguments;
  }
