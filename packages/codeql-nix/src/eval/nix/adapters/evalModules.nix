{
  definitionSources ? [],
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
  emptyLedger = {
    candidates = [];
    opaque = false;
  };
  # The pinned evalModules appends a root whose key equals its declaration file.
  # Obtain that identity from a clean evaluation of the same authenticated lib;
  # user declarations must not be able to substitute the internal root's key.
  internalDeclarations = (effectiveLib.evalModules {modules = [];}).options._module.args.declarations;
  internalFile =
    if builtins.length internalDeclarations == 1 && builtins.isString (builtins.head internalDeclarations)
    then builtins.head internalDeclarations
    else throw "definition inventory internal module identity unavailable";
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
  wrap = inventory: parent: key: module: args: let
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
    plan = builtins.filter (source: isPath && source.path == toString module) definitionSources;
    known = builtins.length plan == 1;
    source = builtins.head plan;
    # Only walk a source-proven attrset path, before sanitize reconstructs it.
    # A property chain can hide opaque inactive content, so it never takes this path.
    position = path: attrs:
      if path == []
      then null
      else if builtins.length path == 1
      then builtins.unsafeGetAttrPos (builtins.head path) attrs
      else position (builtins.tail path) attrs.${builtins.head path};
    ledger = {
      opaque = !known || source.opaque || builtins.any (candidate: candidate.requiresLibrary && (library == null || specialArguments ? lib)) source.candidates;
      candidates =
        if !known
        then []
        else
          map (candidate:
            candidate
            // {
              inherit label;
              moduleKey = normalized.key;
              sourcePath = toString module;
              position =
                if candidate.chain == []
                then position candidate.position applied
                else null;
            }) (builtins.filter (candidate: !candidate.requiresLibrary || (library != null && !(specialArguments ? lib))) source.candidates);
    };
  in
    normalized
    // {
      _file = label;
      config =
        if inventory
        then ledger
        else sanitize normalized.config;
      imports = effectiveLib.imap0 (i: child: wrap inventory label "${normalized.key}:anon-${toString i}" child) normalized.imports;
    };
  evaluated = effectiveLib.evalModules {
    modules = map (module: wrap false "" (toString module) module) modules ++ [{_module.args = moduleArguments;}];
    specialArgs = specialArguments;
  };
in
  evaluated
  // {
    nixqlLibrary = effectiveLib;
    # Upstream owns disabled filtering, reachability and unique-key selection.
    # The same wrappers retain imports/keys/options; only the unused config field
    # carries source plans during collection, never through mergeModules.
    nixqlDefinitionModules =
      (effectiveLib.modules.collectModules
        (specialArguments.modulesPath or "")
        (map (module: wrap true "" (toString module) module) modules
          ++ [
            {config = emptyLedger;}
            {
              _file = internalFile;
              config = emptyLedger;
              key = internalFile;
            }
          ])
        ({
            _class = null;
            _prefix = [];
            config = evaluated.config // {inherit (evaluated) _module;};
            lib = effectiveLib;
            inherit (evaluated) options;
            specialArgs = specialArguments;
          }
          // specialArguments)).modules;
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
