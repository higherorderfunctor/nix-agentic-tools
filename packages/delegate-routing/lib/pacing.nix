# Bind inspection to the checked serving graph, not transport provider names.
{lib}: {
  catalog,
  poolDefinitions,
  techniques,
  budgets ? {},
}: let
  adapters = {
    anthropic-spend = {
      kind = "metered";
      readerPool = null;
      windows = {monthly = ["monthly" "pace"];};
    };
    claude-subscription = {
      kind = "subscription";
      readerPool = "claude";
      windows = {
        fable = ["7d:fable" "pace"];
        weekly = ["7d" "pace"];
      };
    };
    codex-subscription = {
      kind = "subscription";
      readerPool = "codex";
      windows.weekly = ["7d" "pace"];
    };
    opencode-go = {
      kind = "subscription";
      readerPool = "opencode";
      windows = {
        monthly = ["monthly" "pace"];
        rolling = ["5h" "gate"];
        weekly = ["7d" "pace"];
      };
    };
    zai = {
      kind = "subscription";
      readerPool = "zai";
      windows = {
        rolling = ["5h" "gate"];
        weekly = ["7d" "pace"];
      };
    };
  };
  registration = runtime: pool: let
    definition = poolDefinitions.${pool} or {};
    usage = definition.usage or {};
    kinds = builtins.attrNames usage;
    credentialKinds = lib.filter (kind: lib.elem kind ["metered" "subscription"]) (builtins.attrNames (definition.credentials or {}));
    kind = lib.head kinds;
    binding = usage.${kind};
    adapter = adapters.${binding.adapter} or (throw "ai.catalog.pools.${pool}.usage: unknown observation adapter.");
    node = techniques.${binding.runtime}.${binding.technique} or null;
    budget = budgets.${pool}.window or null;
    metered = kind == "metered";
    models = lib.filter (model: catalog.poolFor runtime model == pool) (catalog.modelsFor runtime);
    scopedModels = id:
      if id == "fable"
      then lib.filter (lib.hasPrefix "claude-fable-") models
      else models;
    limits = lib.mapAttrs (id: window: {
      capacity =
        if metered
        then budget.limit
        else 100;
      models = scopedModels id;
      role = lib.elemAt window 1;
      unit =
        if metered
        then "USD"
        else "percentagePoint";
      window = lib.head window;
    }) (lib.filterAttrs (id: _: scopedModels id != []) adapter.windows);
    path = "ai.catalog.pools.${pool}.usage";
  in
    if kinds != credentialKinds
    then throw "${path}: register one adapter/technique for each configured allowance billing kind."
    else if kinds == []
    then {
      limits = {};
      readerPool = pool;
      command = null;
    }
    else if lib.length kinds != 1
    then throw "${path}: inspection requires one allowance billing kind per pool; credit observations are not delivered yet."
    else if adapter.kind != kind
    then throw "${path}.${kind}: associate the adapter with its configured billing kind credential."
    else if node == null || !node.enable || node.kind != "usage" || node.command == null || lib.trim node.command == ""
    then throw "${path}.${kind}.technique: reference an enabled usage technique with a non-empty command."
    else if (budgets.${pool}.usage or null) != null
    then throw "${path}: remove the independent delegate-routing pool Reader registration."
    else if metered && (budget == null || budget.unit != "USD" || budget.limit <= 0)
    then throw "${path}: use the existing accounted monthly USD budget window."
    else {
      inherit limits;
      command = node.command + lib.optionalString metered " --limit ${toString budget.limit} --reset-day ${toString budget.resetDay} --time-zone UTC --pool ${lib.escapeShellArg pool} --now-ms <now-ms>";
      readerPool =
        if adapter.readerPool == null
        then pool
        else adapter.readerPool;
    };
in
  lib.mapAttrs (runtime: pools: let
    registrations = lib.genAttrs pools (registration runtime);
  in {
    inherit runtime;
    pools = registrations;
    routes = map (model: let
      pool = catalog.poolFor runtime model;
    in {
      inherit model pool;
      inherit (catalog.modelFor model) maker;
      limits = builtins.attrNames (lib.filterAttrs (_: limit: lib.elem model limit.models) registrations.${pool}.limits);
    }) (catalog.modelsFor runtime);
  })
  catalog.runtimes
