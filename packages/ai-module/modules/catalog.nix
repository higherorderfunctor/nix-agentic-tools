# Existing credential delivery and family bindings are inputs; only this owner
# composes their serving relation and checks runtime overlap.
{
  config,
  lib,
  options,
  ...
}: let
  catalogLib = import ../lib/catalog/resolve.nix {inherit lib;};
  catalogTypes = import ../lib/catalog/types.nix {inherit lib;};
  providersLib = import ../../cliproxyapi/lib/providers.nix {inherit lib;};
  cfg = config.ai.catalog;
  instances = config.ai.cliproxyapi.instances or {};
  portable = config.ai.programs.delegate-routing or {};
  selection = import ../../delegate-routing/lib/select-families.nix {inherit lib;};
  nativeProviders = {
    anthropic = "claude";
    openai = "codex";
  };
  runtimes = import ../../../lib/ai/runtimes.nix;
  inference = runtime: config.ai.${runtime}.settings.inference or {};
  selectedClient = runtime: instance: client:
    (inference runtime).instance or null
    == instance
    && (inference runtime).clientKey or null == client;
  clientRuntime = instance: client: let
    targets = lib.filter (runtime: selectedClient runtime instance client) runtimes;
  in
    if targets == []
    then ["cliproxyapi:${instance}/${client}"]
    else targets;
  declaredBinding = binding: let
    owners = builtins.attrNames (lib.filterAttrs (_: pool:
      lib.any (credential: credential.binding == binding) (builtins.attrValues pool.credentials))
    cfg.pools);
  in
    if lib.length owners > 1
    then throw "ai.catalog: credential binding ${binding} belongs to multiple pools."
    else if owners == []
    then binding
    else lib.head owners;
  credentialRows = lib.concatLists (lib.mapAttrsToList (instance: settings:
    lib.mapAttrsToList (name: credential: let
      binding = "${instance}/${name}";
      key = credential.apiKey;
      apis =
        if key == null
        then {}
        else lib.filterAttrs (_: value: value != null) key.apis;
    in {
      pool = declaredBinding binding;
      value = {
        credentials.${binding} = {
          inherit binding;
          auth =
            if credential.oauth != null
            then "oauth"
            else "apiKey";
        };
        # The credential module rejects both authentication kinds together.
        # Do not turn that malformed record into competing serving offers.
        models =
          if key == null || credential.oauth != null
          then []
          else lib.unique (lib.concatMap (api: lib.defaultTo [] (lib.defaultTo key.models api.models)) (builtins.attrValues apis));
        providerCatalogs = lib.optional (key == null && credential.oauth != null) credential.oauth.vendor;
      };
    })
    settings.credentials)
  instances);
  # Preserve fit guidance at its owner; translate only its existing budget
  # bindings. Native bindings denote the same open provider catalogs as OAuth.
  routingRows = lib.concatLists (lib.mapAttrsToList (runtime: settings:
    lib.concatMap (family: let
      pool = family.pools.${runtime} or null;
      provider =
        if
          (inference runtime).instance or null
          == null
          && (inference runtime).url or null == null
          && ((runtime == "claude" && family.vendor == "anthropic") || (runtime == "codex" && family.vendor == "openai"))
        then nativeProviders.${family.vendor}
        else null;
    in
      lib.optional (pool != null) {
        inherit pool;
        value = {
          credentials = {};
          models =
            if provider != null
            then []
            else
              lib.filter (id:
                builtins.match ((import ../../delegate-routing/lib/agent-files.nix {inherit lib;}).pattern family.match) id != null) (builtins.attrNames cfg.models);
          providerCatalogs = lib.optional (provider != null) provider;
        };
        inherit runtime;
      }) (selection.select (portable.families or {}) settings.models)) (portable.runtimes or {}));
  mergeRows = rows:
    lib.mapAttrs (_: values: {
      credentials = lib.foldl' (all: value: all // value.credentials) {} values;
      models = lib.unique (lib.concatMap (value: value.models) values);
      providerCatalogs = lib.unique (lib.concatMap (value: value.providerCatalogs) values);
    }) (lib.zipAttrs (map (row: {${row.pool} = row.value;}) rows));
  # Unknown configured API model spellings retain an unknown maker. A runtime
  # combining one with OAuth is refused, rather than classified by a prefix.
  knownSpellings = lib.concatLists (lib.mapAttrsToList (id: model:
    [id] ++ lib.concatLists (builtins.attrValues model.aliases))
  cfg.models);
  configuredModels = lib.genAttrs (lib.filter (id: !lib.elem id knownSpellings)
    (lib.unique (lib.concatMap (row: row.value.models) credentialRows))) (id: {
    aliases = {};
    maker = null;
    source = "configured CPA API-key offer: ${id}";
  });
  models = configuredModels // cfg.models;
  clientRows = lib.concatLists (lib.mapAttrsToList (instance: settings:
    lib.concatLists (lib.mapAttrsToList (client: entry:
      map (runtime: {
        name = runtime;
        value.pools =
          lib.unique (map (route: declaredBinding "${instance}/${route.credential}")
            (lib.filter (route: settings.credentials ? ${route.credential}) entry.routes));
      }) (clientRuntime instance client))
    settings.clientKeys))
  instances);
  inferredRuntimes =
    lib.mapAttrs (_: rows: {pools = lib.unique (lib.concatMap (row: row.pools) rows);})
    (lib.zipAttrs (map (row: {${row.name} = row.value;}) clientRows
        ++ map (row: {${row.runtime}.pools = [row.pool];}) routingRows));
  poolRows = credentialRows ++ routingRows ++ lib.mapAttrsToList (pool: value: {inherit pool value;}) cfg.pools;
  poolDefinitions = mergeRows poolRows;
  runtimeDefinitions = inferredRuntimes // cfg.runtimes;
  # Use CPA's existing API selector, so a chat-only grant cannot advertise
  # models served exclusively by another API on the same credential.
  effectiveRows = lib.concatLists (lib.mapAttrsToList (instance: settings:
    lib.concatLists (lib.mapAttrsToList (client: _:
      lib.concatMap (runtime:
        map (choice: {
          inherit runtime;
          pool = declaredBinding "${instance}/${choice.credential}";
          models = (providersLib.route settings "clientKeys.${client}.routes" choice).models or [];
        }) (lib.filter (choice: settings.credentials ? ${choice.credential}) (projectedRoutes instance client)))
      (clientRuntime instance client))
    settings.clientKeys))
  instances);
  runtimeModels = lib.mapAttrs (runtime: rows:
    lib.mapAttrs (pool: lists:
      lib.unique (lib.concatLists lists
        ++ (cfg.pools.${pool}.models or [])
        ++ lib.concatMap (row: row.value.models) (lib.filter (row: row.runtime == runtime && row.pool == pool) routingRows)))
    (lib.zipAttrs (map (row: {${row.pool} = row.models;}) rows)))
  (lib.groupBy (row: row.runtime) effectiveRows);
  graph = catalogLib.resolve {
    inherit models runtimeModels;
    pools = poolDefinitions;
    inherit (cfg) providers;
    runtimes = runtimeDefinitions;
  };
  projectedRoutes = instance: client: let
    targets = clientRuntime instance client;
    reaches = map (target: lib.sort builtins.lessThan (lib.unique (runtimeDefinitions.${target}.pools or []))) targets;
    original = instances.${instance}.clientKeys.${client}.routes;
    credentials = catalogLib.credentialBindings poolDefinitions (lib.head reaches);
    allowed = lib.filter (credential: lib.hasPrefix "${instance}/" credential.binding) credentials;
    names = map (credential: lib.removePrefix "${instance}/" credential.binding) allowed;
    routes =
      # Preserve malformed routes for the credential owner's named diagnostic.
      lib.filter (choice: !(instances.${instance}.credentials ? ${choice.credential}) || lib.elem choice.credential names) original
      ++ map (credential: {
        inherit credential;
        api = null;
      })
      (lib.filter (name: !lib.any (choice: choice.credential == name) original) names);
  in
    if !lib.all (reach: reach == lib.head reaches) reaches
    then throw "ai.catalog: runtimes sharing client ${instance}/${client} must have identical pool reach."
    else if routes == []
    then throw "ai.catalog: client ${instance}/${client} has no reachable credential."
    else lib.unique routes;
in {
  options.ai.catalog = {
    models = lib.mkOption {
      type = lib.types.attrsOf catalogTypes.model;
      default = {};
      apply = entries: catalogLib.defaults.models // entries;
      description = "Canonical model identities, extending the extracted catalog.";
    };
    pools = lib.mkOption {
      type = lib.types.attrsOf catalogTypes.pool;
      default = {};
      description = "Shared budgets and their credential bindings; actual CPA offers are included automatically.";
    };
    providers = lib.mkOption {
      type = lib.types.attrsOf catalogTypes.provider;
      default = {};
      apply = entries: catalogLib.defaults.providers // entries;
      description = "Open OAuth catalog maker identities, separate from serving vendor names.";
    };
    runtimes = lib.mkOption {
      type = lib.types.attrsOf catalogTypes.runtime;
      default = {};
      description = "Explicit pool reach, replacing the reach derived from existing client routes and budget bindings.";
    };
    resolved = lib.mkOption {
      type = lib.types.raw;
      readOnly = true;
      internal = true;
      description = "Checked graph consumed by CPA and routing, including client-route projection.";
    };
  };
  config =
    {
      ai.catalog.resolved =
        graph
        // {
          clientRoutes = instance: client: builtins.seq graph.runtimes (projectedRoutes instance client);
        };
    }
    // lib.optionalAttrs (options ? assertions) {
      assertions =
        map (message: {
          assertion = false;
          inherit message;
        })
        graph.errors;
    };
}
