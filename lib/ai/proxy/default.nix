# A Harness selects a named Instance client key or an external CPA origin.
{lib}: let
  inherit (lib) mkOption types;
  redact = import ../../redact {inherit lib;};
  instancesLib = import ../../../packages/ai-module/lib/instances.nix {inherit lib;};
  urlPattern = "https?://([A-Za-z0-9.-]+|\\[[0-9A-Fa-f:.]+[]])(:[0-9]+)?";
  urlDescription = "the proxy origin only, `http://<host>:<port>`, with no path";
  selectionOptions = {
    clientKey = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Named client key of the selected Instance; its key and routes belong to that Instance.";
    };
    instance = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "main";
      description = "An `ai.cliproxyapi.instances` or `ai.airlock.instances` entry, selected with `clientKey`.";
    };
    key = mkOption {
      type = types.nullOr redact.types.redacted;
      default = null;
      description = "Client key for an external `url`, as a redact reference read when the Harness starts.";
    };
    url = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "External CPA origin, selected with `key`: ${urlDescription}.";
    };
  };
  isSelected = selection: selection.url != null || selection.instance != null;
  selectionFor = root: runtime:
    if isSelected runtime
    then runtime
    else root;
  # Per instance owner: where an instance keeps its named clients, and what
  # selecting one of them resolves to beyond `owner` and `url`. Each owner
  # claims its instance names in `ai.claims.proxy-instance`.
  owners = {
    airlock = {
      clients = instance: lib.defaultTo {} instance.settings.clients;
      clientsOption = "settings.clients";
      resolved = {
        clientKey,
        instance,
        name,
        ...
      }: {
        inherit (instance) port;
        client = clientKey;
        credentials = [];
        instance = name;
      };
    };
    cliproxyapi = {
      clients = instance: instance.clientKeys;
      clientsOption = "clientKeys";
      resolved = {
        client,
        instance,
        ...
      }: {
        inherit (client) key;
        credentials = map (route: {
          name = route.credential;
          models = instance.credentials.${route.credential}.apiKey.models or [];
        }) (builtins.filter (route: builtins.hasAttr route.credential instance.credentials) client.routes);
      };
    };
  };
  instancesFor = config: lib.mapAttrs (owner: _: config.ai.${owner}.instances or {}) owners;
  # The owner and instance `name` selects, or null when no owner has it.
  # `ai.claims.proxy-instance` keeps instance names unique across owners.
  lookup = instances: name: let
    owner = lib.findFirst (owner: builtins.hasAttr name instances.${owner}) null (builtins.attrNames owners);
  in
    if name == null || owner == null
    then null
    else {
      inherit owner;
      inherit (owners.${owner}) clientsOption;
      instance = instances.${owner}.${name};
      clients = owners.${owner}.clients instances.${owner}.${name};
    };
  # `{url}` for the enabled instance `name`, or `{problem}` saying why `path`
  # cannot select it.
  instanceSelection = instances: path: name: let
    found = lookup instances name;
    option = "${lib.showOption path}.instance";
  in
    if found == null
    then {problem = "${option} names `${name}`, which is not an ${lib.concatMapStringsSep " or " (owner: "`ai.${owner}.instances`") (builtins.attrNames owners)} entry.";}
    else
      instancesLib.select {
        instances = instances.${found.owner};
        inherit name option;
        inherit (found) owner;
      };
  problems = instances: path: selection: let
    name = lib.showOption path;
    has = field: selection.${field} != null;
    found = lookup instances selection.instance;
  in
    lib.optional (has "url" && has "instance") "${name}.url and ${name}.instance both select a proxy; set one."
    ++ lib.optional (has "url" && !has "key") "${name}.url needs `key`: without one the Harness may send its own login token to CPA."
    ++ lib.optional (has "key" && !has "url") "${name}.key is set without `url`; Instance selections use `clientKey`."
    ++ lib.optional (has "instance" && !has "clientKey") "${name}.instance needs `clientKey`."
    ++ lib.optional (has "clientKey" && !has "instance") "${name}.clientKey is set without `instance`."
    ++ lib.optionals (has "url") (lib.optional (builtins.match urlPattern selection.url == null) "${name}.url must be ${urlDescription}; got `${selection.url}`.")
    ++ lib.optionals (has "instance") (lib.toList ((instanceSelection instances path selection.instance).problem or []))
    ++ lib.optional (has "clientKey" && found != null && !(builtins.hasAttr selection.clientKey found.clients))
    "${name}.clientKey names `${selection.clientKey}`, which is not an `ai.${found.owner}.instances.${selection.instance}.${found.clientsOption}` entry.";
  resolve = {
    instances,
    root,
    runtime,
  }: let
    selection = selectionFor root runtime;
    selected = instanceSelection instances [] selection.instance;
    found = lookup instances selection.instance;
    client =
      if found == null || selection.clientKey == null
      then null
      else found.clients.${selection.clientKey} or null;
  in
    if !isSelected selection
    then null
    else if selection.instance == null
    then {
      inherit (selection) key url;
      credentials = [];
      owner = "cliproxyapi";
    }
    else if selected ? problem || client == null
    then null
    else
      owners.${found.owner}.resolved {
        inherit client;
        inherit (found) instance;
        inherit (selection) clientKey;
        name = selection.instance;
      }
      // {
        inherit (found) owner;
        inherit (selected) url;
      };
in {
  inherit instancesFor resolve selectionFor;
  assertionsFor = instances: path: selection:
    map (message: {
      assertion = false;
      inherit message;
    }) (problems instances path selection);
  rootOption = mkOption {
    type = types.submodule {options = selectionOptions;};
    default = {};
    description = "Point a Harness at a named CPA instance (Claude or Codex) or Airlock instance (Claude only) with `instance` + `clientKey`, or external `url` + `key`. A per-Harness selection replaces this whole selection. Instance routes select named upstream credentials; no Harness publishes keys or rules.";
  };
  runtimeOptions = selectionOptions;
  resolvedType = types.nullOr (types.submodule {
    options = {
      client = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Airlock only: the selected `settings.clients` name.";
      };
      credentials = mkOption {
        type = types.listOf (types.submodule {
          options = {
            models = mkOption {type = types.listOf types.str;};
            name = mkOption {type = types.str;};
          };
        });
        default = [];
        description = "Named upstream credentials in client route order, with declared API-key models.";
      };
      instance = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Airlock only: the selected instance name.";
      };
      key = mkOption {
        type = types.nullOr redact.types.redacted;
        default = null;
        description = "The key sent to CPA or an external `url` proxy; null for Airlock.";
      };
      owner = mkOption {
        type = types.enum (builtins.attrNames owners);
        description = "Which instance owner the selection resolved to; an external `url` counts as CPA.";
      };
      port = mkOption {
        type = types.nullOr types.port;
        default = null;
        description = "Airlock only: the selected instance's loopback port.";
      };
      url = mkOption {
        type = types.strMatching urlPattern;
        description = "CPA origin without a path.";
      };
    };
  });
}
