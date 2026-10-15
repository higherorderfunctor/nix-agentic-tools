# CLIProxyAPI's configuration and auth-file fields as option types, read from
# the drift-checked sidecar `packages/cliproxyapi/extracted/` and its hand
# rows (../extract/rules.nix).
#
# The sidecar is read as an ordinary committed file. Never read the
# package's `passthru.extracted` derivation here: that is
# import-from-derivation. Freshness belongs to the update job and the
# `cliproxyapi-extracted` drift check.
#
#   settingsType  the v8 configuration: one option per extracted path, each
#                 `nullOr` with default null, every object open to keys the
#                 extraction does not know (a newer CPA, plugin settings).
#   render        a settings value -> `{ value; secrets; }`: `value` with
#                 nulls dropped and each secret replaced by its `plain` value
#                 or left out, `secrets` the `file` or `helper` ones with
#                 their JSON path, for the start script to read and set.
#   accountType   the auth-file fields the extraction found CPA reading,
#                 nulls meaning unset, open to any other key (fields CPA's
#                 executors and panel use off the extracted path, such as
#                 `request_retry`), a `secret` row's strings taking a secret.
#                 The open keys refuse the login's identity and tokens: an
#                 `ignored` row's field at the top level, or a name
#                 open-keys' credential policy refuses (`access_token`,
#                 `api_key`) at any depth.
#   configFilter  ./config.jq, the jq program that completes `render`'s
#                 value at run time: secrets, client key, auth dir.
#   knownAccounts open-keys `known` data for the unknown-account-key
#                 warning: a map of account names to the typed field names.
#   knownSettings the extracted configuration paths, `<name>` maps as `*`, as
#                 open-keys `known` data for the unknown-settings warning.
#   renderAccount an account value -> `{ value; secrets; }`, as `render`.
#   tree          `nodes` (path -> node) and `fieldsAt` (an object's
#                 key -> path), for checks that walk every path.
#
# `jsonType` is `(pkgs.formats.json {}).type`, passed in because the option
# modules that call this exist before `pkgs` does.
{lib}: let
  inherit (lib) mkOption types;
  credentials = import ../../../lib/credentials.nix {inherit lib;};
  inherit (import ../extract/rules.nix {inherit lib;}) accounts config;
  openKeys = import ../../../lib/open-keys {inherit lib;};

  # Path grammar (the extractor's): `.` between keys, `[]` for a list
  # element, `.<name>` for a map value.
  parentOf = path:
    if lib.hasSuffix "[]" path
    then lib.removeSuffix "[]" path
    else let
      split = builtins.match "(.*)\\.[^.]*" path;
    in
      if split == null
      then ""
      else builtins.head split;
  join = parent: key:
    if parent == ""
    then key
    else "${parent}.${key}";
  ancestors = path:
    lib.optionals (path != "") ([path] ++ ancestors (parentOf path));

  # Mappings the extraction names only through their children, such as
  # `server` or `upstream.claude.header-defaults`, are plain objects.
  nodes =
    builtins.listToAttrs (map (path: lib.nameValuePair path {type = "object";})
      (lib.concatMap (path: ancestors (parentOf path)) (builtins.attrNames config.entries)))
    // config.entries;
  children = lib.groupBy parentOf (builtins.attrNames nodes);
  # An object's fields: key -> path.
  fieldsAt = parent:
    builtins.listToAttrs (map (path: lib.nameValuePair (lib.removePrefix (join parent "") path) path)
      (builtins.filter (path: path != "${parent}[]" && path != "${parent}.<name>") (children.${parent} or [])));

  secretNote = reason: "${reason} Set `plain`, `file` or `helper`; a `file` or `helper` is read when the service starts, so only its path reaches the store.";
  describe = node:
    lib.concatStringsSep "\n\n" (lib.unique (builtins.filter (text: text != "") [
      (node.description or "")
      (node.template or "")
      (lib.optionalString (node ? secret) (secretNote node.secret))
    ]));

  typeAt = jsonType: path: let
    node = nodes.${path};
  in
    if node ? secret
    then credentials.mkSecretType {}
    else if node ? enum
    then types.enum node.enum
    else
      {
        inherit (types) bool int number;
        any = jsonType;
        duration = types.str;
        list = types.listOf (typeAt jsonType "${path}[]");
        map = types.attrsOf (typeAt jsonType "${path}.<name>");
        object = types.submodule {
          freeformType = jsonType;
          options = optionsAt jsonType path;
        };
        string = types.str;
      }
      .${
        node.type
      }
      or (throw "packages/cliproxyapi/extracted/: ${path} has type `${node.type}`, which packages/cliproxyapi/lib/extracted.nix does not handle");

  optionsAt = jsonType: parent:
    lib.mapAttrs (_: path:
      mkOption {
        type = types.nullOr (typeAt jsonType path);
        default = null;
        description = describe nodes.${path};
      })
    (fieldsAt parent);

  # A secret value -> its `plain` literal, or nothing plus the secret at `at`
  # for the start script to read and set.
  resolve = at: value:
    if value ? plain
    then {
      value = value.plain;
      secrets = [];
    }
    else {
      value = null;
      secrets = [
        {
          path = at;
          secret = value;
        }
      ];
    };
  collect = results: lib.concatMap (result: result.secrets) results;

  # Walks a value along the tree: typed objects lose null fields and empty
  # typed children, secrets resolve, anything the tree does not know passes
  # through untouched. `at` is the JSON path, list indices as numbers.
  walk = path: at: value: let
    node = nodes.${path} or null;
    container = path == "" || builtins.elem (node.type or null) ["map" "object"];
    childPath = name:
      if (node.type or null) == "map"
      then "${path}.<name>"
      else join path name;
  in
    if value == null
    then {
      value = null;
      secrets = [];
    }
    else if node ? secret
    then resolve at value
    else if builtins.isAttrs value && container
    then let
      results = lib.mapAttrs (name: walk (childPath name) (at ++ [name])) value;
      kept = lib.filterAttrs (name: result: result.value != null && !(result.value == {} && (nodes.${childPath name}.type or null) == "object")) results;
    in {
      value = lib.mapAttrs (_: result: result.value) kept;
      secrets = collect (builtins.attrValues results);
    }
    else if builtins.isList value && (node.type or null) == "list"
    then let
      results = lib.imap0 (index: walk "${path}[]" (at ++ [index])) value;
    in {
      value = map (result: result.value) results;
      secrets = collect results;
    }
    else {
      inherit value;
      secrets = [];
    };

  # An auth-file field's Go type, as the extraction or its row gives it; a
  # `secret` field's strings take the secret type.
  goType = jsonType: secret: type:
    if lib.hasPrefix "[]" type
    then types.listOf (goType jsonType secret (lib.removePrefix "[]" type))
    else if lib.hasPrefix "map[string]" type
    then types.attrsOf (goType jsonType secret (lib.removePrefix "map[string]" type))
    else
      {
        inherit (types) bool int;
        any = jsonType;
        float64 = types.number;
        string =
          if secret
          then credentials.mkSecretType {}
          else types.str;
      }
      .${
        type
      }
      or (throw "packages/cliproxyapi/extracted/: auth-file type `${type}` is not handled by packages/cliproxyapi/lib/extracted.nix");

  # Splits a secret field's value along its Go type, as `walk` does: each
  # string is a secret.
  splitSecrets = type: at: value:
    if lib.hasPrefix "[]" type
    then let
      results = lib.imap0 (index: splitSecrets (lib.removePrefix "[]" type) (at ++ [index])) value;
    in {
      value = map (result: result.value) results;
      secrets = collect results;
    }
    else if lib.hasPrefix "map[string]" type
    then let
      results = lib.mapAttrs (name: splitSecrets (lib.removePrefix "map[string]" type) (at ++ [name])) value;
    in {
      value = lib.mapAttrs (_: result: result.value) (lib.filterAttrs (_: result: result.value != null) results);
      secrets = collect (builtins.attrValues results);
    }
    else resolve at value;
in {
  accountType = {jsonType}:
    types.submodule {
      freeformType = openKeys.refuse {
        type = jsonType;
        reasons = accounts.ignored;
      };
      options = lib.mapAttrs (field: entry:
        mkOption {
          type = types.nullOr (goType jsonType (entry ? secret) entry.type);
          default = null;
          description = lib.concatStringsSep "\n\n" ([
              "The auth file's `${field}`${lib.optionalString (entry ? aliases) " (also read as ${lib.concatMapStringsSep ", " (alias: "`${alias}`") entry.aliases})"}."
            ]
            ++ lib.optional (entry ? secret) (secretNote entry.secret));
        })
      accounts.entries;
    };

  configFilter = ./config.jq;

  knownAccounts.map = openKeys.fromPaths {
    names = builtins.attrNames accounts.entries;
    paths = [];
  };
  knownSettings = openKeys.fromPaths {
    paths = map (lib.replaceStrings [".<name>"] [".*"]) (builtins.attrNames config.entries);
  };

  render = walk "" [];

  # Nulls dropped; a field that held only `file` or `helper` secrets is left
  # out, its secrets returned with their paths inside the account's fields.
  renderAccount = fields: let
    results = lib.mapAttrs (field: value:
      if accounts.entries.${field}.secret or null != null
      then splitSecrets accounts.entries.${field}.type [field] value
      else {
        inherit value;
        secrets = [];
      })
    (lib.filterAttrs (_: value: value != null) fields);
  in {
    value = lib.mapAttrs (_: result: result.value) (lib.filterAttrs (_: result: result.value != null && !(result.value == {} && result.secrets != [])) results);
    secrets = collect (builtins.attrValues results);
  };

  # The tree itself, for checks that walk every path.
  tree = {inherit fieldsAt nodes;};

  settingsType = {jsonType}:
    types.submodule {
      freeformType = jsonType;
      options = optionsAt jsonType "";
    };
}
