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
  instancesFor = config: {
    airlock = config.ai.airlock.instances or {};
    cliproxyapi = config.ai.cliproxyapi.instances or {};
  };
  ownerOf = instances: name:
    if name != null && builtins.hasAttr name instances.airlock
    then "airlock"
    else "cliproxyapi";
  clientsOf = owner: instance:
    if instance == null
    then {}
    else if owner == "airlock"
    then
      (
        if instance.settings.clients == null
        then {}
        else instance.settings.clients
      )
    else instance.clientKeys;
  instanceSelection = instances: path: selection: let
    owner = ownerOf instances selection.instance;
  in
    instancesLib.select {
      instances = instances.${owner};
      name = selection.instance;
      option = "${lib.showOption path}.instance";
      inherit owner;
    };
  problems = instances: path: selection: let
    name = lib.showOption path;
    has = field: selection.${field} != null;
    owner = ownerOf instances selection.instance;
    instance =
      if selection.instance == null
      then null
      else instances.${owner}.${selection.instance} or null;
  in
    lib.optional (has "url" && has "instance") "${name}.url and ${name}.instance both select a proxy; set one."
    ++ lib.optional (has "url" && !has "key") "${name}.url needs `key`: without one the Harness may send its own login token to CPA."
    ++ lib.optional (has "key" && !has "url") "${name}.key is set without `url`; Instance selections use `clientKey`."
    ++ lib.optional (has "instance" && !has "clientKey") "${name}.instance needs `clientKey`."
    ++ lib.optional (has "clientKey" && !has "instance") "${name}.clientKey is set without `instance`."
    ++ lib.optionals (has "url") (lib.optional (builtins.match urlPattern selection.url == null) "${name}.url must be ${urlDescription}; got `${selection.url}`.")
    ++ lib.optionals (has "instance") (lib.toList ((instanceSelection instances path selection).problem or []))
    ++ lib.optional (has "instance" && has "clientKey" && instance != null && !(builtins.hasAttr selection.clientKey (clientsOf owner instance)))
    "${name}.clientKey names `${selection.clientKey}`, which is not an `ai.${owner}.instances.${selection.instance}.${
      if owner == "airlock"
      then "settings.clients"
      else "clientKeys"
    }` entry.";
  resolve = {
    instances,
    root,
    runtime,
  }: let
    selection = selectionFor root runtime;
    selected =
      if selection.instance == null
      then null
      else instanceSelection instances [] selection;
    owner = ownerOf instances selection.instance;
    instance =
      if selection.instance == null
      then null
      else instances.${owner}.${selection.instance} or null;
    client =
      if instance == null || selection.clientKey == null
      then null
      else (clientsOf owner instance).${selection.clientKey} or null;
  in
    if !isSelected selection
    then null
    else if selection.instance == null
    then {
      inherit (selection) key url;
      credentials = [];
    }
    else if selected ? problem || client == null
    then null
    else if owner == "airlock"
    then {
      inherit owner;
      inherit (selection) instance;
      inherit (instance) port;
      inherit (selected) url;
      client = selection.clientKey;
      credentials = [];
    }
    else {
      inherit (client) key;
      inherit (selected) url;
      credentials = map (route: {
        name = route.credential;
        models = instance.credentials.${route.credential}.apiKey.models or [];
      }) (builtins.filter (route: builtins.hasAttr route.credential instance.credentials) client.routes);
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
      };
      key = mkOption {
        type = types.nullOr redact.types.redacted;
        default = null;
        description = "The selected client key.";
      };
      owner = mkOption {
        type = types.enum ["airlock" "cliproxyapi"];
        default = "cliproxyapi";
      };
      port = mkOption {
        type = types.nullOr types.port;
        default = null;
      };
      url = mkOption {
        type = types.strMatching urlPattern;
        description = "CPA origin without a path.";
      };
    };
  });
}
