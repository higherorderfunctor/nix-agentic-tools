# cspell:ignore highestPrio
{
  lib,
  pkgs,
}: let
  inherit (lib) mkOption types;
  formats = ["json" "markdown" "raw" "toml" "yaml"];
  methods = ["ro" "rw" "symlink"];
  contentFields = ["run" "source" "text" "value"];
  methodType = types.enum methods;
  defaulted = type: default: mkOption {inherit type default;};
  nullable = type:
    mkOption {
      type = types.nullOr type;
      default = null;
    };
  internalChoice = mkOption {
    type = types.nullOr types.str;
    internal = true;
    readOnly = true;
  };
  selectContent = config: options: let
    priority = field: options.${field}.highestPrio;
    levels = lib.unique (builtins.sort builtins.lessThan (map priority contentFields));
    # The strongest level with a non-null field wins; weaker fields stay unevaluated.
    present = lib.findFirst (fields: fields != []) [] (map (level: builtins.filter (field: priority field == level && config.${field} != null) contentFields) levels);
  in {
    choice =
      if builtins.length present == 1
      then builtins.head present
      else null;
    tie =
      if builtins.length present > 1
      then "content alternatives tie at priority ${toString (priority (builtins.head present))}: ${lib.concatStringsSep ", " present}"
      else null;
  };
  storeString = types.addCheck (types.strMatching "/nix/store/[a-z0-9]{32}-[^/]+(/[^/]+)*") (source: lib.all (segment: segment != "." && segment != "..") (lib.splitString "/" source));
  contentType = types.submodule ({
    config,
    options,
    ...
  }: {
    options = {
      _choice = internalChoice;
      _tie = internalChoice;
      run = nullable types.lines;
      # A derivation coerces to its output path; a string must name a store
      # path without dot segments (refuses `/etc/passwd` and `<store>/../..`).
      source = nullable (types.either (types.addCheck types.path builtins.isPath) (types.coercedTo types.package (drv: "${drv}") storeString));
      text = nullable types.str;
      value = nullable (types.attrsOf types.anything);
    };
    config = {
      _choice = (selectContent config options).choice;
      _tie = (selectContent config options).tie;
    };
  });
  entryType = types.submodule {
    options = {
      content = defaulted contentType {};
      enable = defaulted types.bool true;
      executable = nullable types.bool;
      format = defaulted (types.enum formats) "raw";
      method = mkOption {
        type = types.either methodType (types.submodule {
          options = {
            devenv = mkOption {type = methodType;};
            hm = mkOption {type = methodType;};
          };
        });
        default = "symlink";
      };
      mode = nullable (types.strMatching "0?[0-7]{3}");
      recursive = defaulted types.bool false;
      # Derivations built before the entry is delivered, never read: a
      # generated tree whose checks gate an entry that does not point into it.
      requires = mkOption {
        type = types.listOf types.package;
        default = [];
        internal = true;
        visible = false;
      };
    };
  };
  # An `own.py` ledger the engine imports into its state once.
  legacyLedgerType = types.submodule {
    options = {
      codec = mkOption {type = types.enum ["dir" "json"];};
      ledger = mkOption {type = types.str;};
      path = mkOption {type = types.str;};
    };
  };
  validPath = path:
    path
    != ""
    && !lib.hasPrefix "/" path
    && lib.all (part: part != "" && part != "." && part != "..") (lib.splitString "/" path);
  isDirectory = source: builtins.pathExists "${toString source}/.";
  jsonCompatible = value: let
    kind = builtins.typeOf value;
  in
    builtins.elem kind ["null" "bool" "int" "float" "string"]
    || (kind == "list" && lib.all jsonCompatible value)
    || (kind == "set" && lib.all jsonCompatible (builtins.attrValues value));
  nullPath = prefix: value: let
    kind = builtins.typeOf value;
    nested =
      if kind == "set"
      then map (name: nullPath (prefix ++ [name]) value.${name}) (builtins.attrNames value)
      else if kind == "list"
      then lib.imap0 (index: item: nullPath (prefix ++ [toString index]) item) value
      else [];
  in
    if kind == "null"
    then "/${lib.concatStringsSep "/" prefix}"
    else lib.findFirst (path: path != null) null nested;
  error = path: message: ''files2."${path}": ${message}'';
  renderValue = format: value:
    if format == "json"
    then pkgs.writeText "files2-value.json" (builtins.toJSON value)
    else let
      python = pkgs.python3.withPackages (ps: [ps.pyyaml ps.tomlkit]);
    in
      pkgs.runCommandLocal "files2-value.${format}" {
        input = builtins.toJSON value;
        passAsFile = ["input"];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        ${python}/bin/python3 -I ${./files2_codecs.py} ${format} < "$inputPath" > "$out"
      '';
  resolveMethod = backend: method:
    if builtins.isString method
    then method
    else method.${backend};
  # A symlink is never followed: it is one leaf, so a directory symlink is
  # delivered as one link, as Home Manager's recursive link and the old devenv
  # walk did. `ro` copies file bytes, and a directory symlink has none to copy.
  walk = method: target: source: let
    entries = builtins.readDir source;
    visit = name: let
      child = source + "/${name}";
      leaf = "${target}/${name}";
      kind = entries.${name};
    in
      if kind == "directory"
      then walk method leaf child
      else [
        ({
            path = leaf;
            source = child;
          }
          // lib.optionalAttrs (method == "ro" && kind == "symlink" && isDirectory child) {
            error = error target ''recursive ro source contains a directory symlink at "${leaf}"'';
          })
      ];
  in
    lib.concatMap visit (builtins.attrNames entries);
  inspect = backend: path: entry: let
    choice = entry.content._choice;
    method = resolveMethod backend entry.method;
    source =
      if choice == "source"
      then entry.content.source
      else null;
    # Probe the source only when recursing: probing a derivation output at
    # evaluation would build it (import-from-derivation). A non-recursive
    # directory used as an ro source is refused by the engine at runtime.
    directory = source != null && entry.recursive && isDirectory source;
    value =
      if choice == "value"
      then entry.content.value
      else null;
    nullKey =
      if value == null
      then null
      else nullPath [] value;
    problem =
      if !validPath path
      then "target must be a normalized relative path without empty, . or .. segments"
      else if !entry.enable
      then null
      else if entry.content._tie != null
      then entry.content._tie
      else if choice == null
      then "set one of content.text, content.source, content.value, content.run"
      else if choice == "value" && builtins.elem entry.format ["markdown" "raw"]
      then "content.value requires json, toml or yaml format"
      else if method == "rw" && builtins.elem entry.format ["markdown" "raw"]
      then "rw requires json, toml or yaml format"
      else if entry.recursive && method == "rw"
      then "rw cannot be recursive"
      else if entry.recursive && !directory
      then "recursive requires content.source to be a directory"
      else if choice == "run" && method == "symlink"
      then "content.run requires ro or rw method"
      else if entry.mode != null && method == "symlink"
      then "mode requires ro or rw method"
      else if entry.mode != null && entry.executable != null
      then "mode and executable cannot both be set"
      else if method == "ro" && entry.mode != null && !builtins.elem (builtins.substring (builtins.stringLength entry.mode - 3) 1 entry.mode) ["4" "5" "6" "7"]
      then "ro mode must grant owner read permission"
      else if value != null && !jsonCompatible value
      then "content.value must contain only null, booleans, numbers, strings, lists and string-keyed maps"
      else if value != null && entry.format == "toml" && nullKey != null
      then ''TOML cannot represent null at "${nullKey}"''
      else null;
    leaves =
      if !entry.enable || problem != null
      then []
      else if entry.recursive
      then walk method path source
      else [{inherit path source;}];
    # The delivered content carries `requires`' string context after the walk,
    # since `readDir` would build it at evaluation.
    pin = content:
      if entry.requires == []
      then content
      else "${content}${lib.concatMapStrings (drv: builtins.substring 0 0 "${drv}") entry.requires}";
    plan = leaf: {
      inherit (entry) executable format mode;
      inherit method;
      inherit (leaf) path;
      content =
        if entry.recursive
        then {source = pin leaf.source;}
        else if choice == "value"
        then {
          value = entry.content.value;
          rendered = pin (renderValue entry.format entry.content.value);
        }
        else {"${choice}" = pin entry.content.${choice};};
      inherit (entry) recursive;
    };
  in
    builtins.deepSeq (
      if entry.enable
      then {
        inherit (entry) enable executable format method mode recursive;
        selectedContent =
          if choice == null
          then null
          else entry.content.${choice};
      }
      else {}
    ) {
      issue =
        if problem == null
        then null
        else error path problem;
      entries = map plan leaves;
      leafIssue = let
        bad = lib.findFirst (leaf: leaf ? error) null leaves;
      in
        if bad == null
        then null
        else bad.error;
    };
  validate = {
    backend,
    files,
    namespace,
  }: let
    names = builtins.attrNames files;
    inspected = map (path: inspect backend path files.${path}) names;
    leaves = lib.concatMap (item: item.entries) inspected;
    sorted = builtins.sort (a: b: a.path < b.path) leaves;
    overlaps = seen: rest:
      if rest == []
      then null
      else let
        current = builtins.head rest;
        other = lib.findFirst (prior: prior.path == current.path || lib.hasPrefix "${prior.path}/" current.path) null seen;
      in
        if other != null
        then error current.path ''destination overlaps "${other.path}"''
        else overlaps (seen ++ [current]) (builtins.tail rest);
    firstIssue = lib.findFirst (issue: issue != null) null (lib.concatMap (item: [item.issue item.leafIssue]) inspected);
  in
    if !validPath namespace || lib.hasInfix "/" namespace
    then "files2: namespace must be one normalized path segment"
    else if firstIssue != null
    then firstIssue
    else overlaps [] sorted;
  normalize = {
    backend,
    files,
    namespace,
    owners ? {},
  }: let
    ownerIssue = validateOwners owners;
    issue = validate {inherit backend files namespace;};
    entries = lib.concatMap (path: (inspect backend path files.${path}).entries) (builtins.attrNames files);
  in
    if ownerIssue != null
    then throw ownerIssue
    else if issue != null
    then throw issue
    else builtins.sort (a: b: a.path < b.path) entries;
  # `owners` maps each layer-1 destination to the runtimes declaring it.
  validateOwners = owners: let
    shared = lib.findFirst (path: builtins.length owners.${path} > 1) null (builtins.attrNames owners);
  in
    if shared == null
    then null
    else error shared "runtime owners ${lib.concatStringsSep " and " (lib.sort lib.lessThan owners.${shared})} claim one destination";
in {
  inherit entryType legacyLedgerType normalize validate validateOwners;
}
