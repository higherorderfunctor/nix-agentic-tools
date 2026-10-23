# A Harness selects a named Instance client key or an external CPA origin.
{lib}: let
  inherit (lib) mkOption types;
  exact = import ../../../packages/cliproxyapi/lib/exact-models.nix {inherit lib;};
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
      description = "An `ai.cliproxyapi.instances` entry, selected with `clientKey`.";
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
  instanceSelection = instances: path: selection:
    instancesLib.select {
      inherit instances;
      name = selection.instance;
      option = "${lib.showOption path}.instance";
      owner = "cliproxyapi";
    };
  problems = instances: path: selection: let
    name = lib.showOption path;
    has = field: selection.${field} != null;
    instance = instances.${selection.instance} or null;
  in
    lib.optional (has "url" && has "instance") "${name}.url and ${name}.instance both select a proxy; set one."
    ++ lib.optional (has "url" && !has "key") "${name}.url needs `key`: without one the Harness may send its own login token to CPA."
    ++ lib.optional (has "key" && !has "url") "${name}.key is set without `url`; Instance selections use `clientKey`."
    ++ lib.optional (has "instance" && !has "clientKey") "${name}.instance needs `clientKey`."
    ++ lib.optional (has "clientKey" && !has "instance") "${name}.clientKey is set without `instance`."
    ++ lib.optionals (has "url") (lib.optional (builtins.match urlPattern selection.url == null) "${name}.url must be ${urlDescription}; got `${selection.url}`.")
    ++ lib.optionals (has "instance") (lib.toList ((instanceSelection instances path selection).problem or []))
    ++ lib.optional (has "instance" && has "clientKey" && instance != null && !(builtins.hasAttr selection.clientKey instance.clientKeys))
    "${name}.clientKey names `${selection.clientKey}`, which is not an `ai.cliproxyapi.instances.${selection.instance}.clientKeys` entry.";
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
    instance = instances.${selection.instance} or null;
    client =
      if instance == null || selection.clientKey == null
      then null
      else instance.clientKeys.${selection.clientKey} or null;
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
    else {
      inherit (client) key;
      inherit (selected) url;
      models =
        if instance.gate.enable && (client.models != null || client.excludedModels != null)
        then exact.clientModels instance client
        else null;
      credentials = map (route: {
        name = route.credential;
        models = instance.credentials.${route.credential}.apiKey.models or [];
      }) (builtins.filter (route: builtins.hasAttr route.credential instance.credentials) client.routes);
    };
in {
  inherit resolve selectionFor;
  assertionsFor = instances: path: selection:
    map (message: {
      assertion = false;
      inherit message;
    }) (problems instances path selection);
  rootOption = mkOption {
    type = types.submodule {options = selectionOptions;};
    default = {};
    description = "Point a Harness (Claude Code or Codex CLI) at CPA with `instance` + `clientKey`, or external `url` + `key`. A per-Harness selection replaces this whole selection. Instance routes select named upstream credentials; no Harness publishes keys or rules.";
  };
  runtimeOptions = selectionOptions;
  resolvedType = types.nullOr (types.submodule {
    options = {
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
      key = mkOption {
        type = redact.types.redacted;
        description = "The selected client key.";
      };
      models = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = null;
        description = "Exact model set enforced by the selected instance gate, or null without a client model list.";
      };
      url = mkOption {
        type = types.strMatching urlPattern;
        description = "CPA origin without a path.";
      };
    };
  });
}
