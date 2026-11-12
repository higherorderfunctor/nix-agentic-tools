# The shared serving relation. No fit, prices, usage or launch policy lives here.
{lib}: let
  facts = import ../../../../lib/extracted/facts.nix {inherit lib;};
  cpa = facts.get (facts.load {dir = ../../../cliproxyapi/extracted;}).aggregate;
  claude = facts.get (facts.load {dir = ../../../claude-code/extracted;}).aggregate "models";
  codex = facts.get (facts.load {dir = ../../../chatgpt-codex/extracted;}).aggregate "models";
  opencodeGo = cpa "opencodeGo";
  zAi = cpa "zAi";
  identity = maker: source: {
    inherit maker source;
    aliases = {};
  };
  native = maker: source: ids: lib.genAttrs ids (_: identity maker source);
  # An undisclosed maker keeps its own identity, never a guessed vendor.
  goMakerFacts.iceman-contributor-free = {
    maker = "iceman";
    source = "dcaf19f9:packages/delegate-routing/lib/opencode-go.nix:132";
  };
  # canonical_id carries the maker namespace; owned_by is the serving vendor.
  goModels = lib.mapAttrs (id: model: let
    canonical = model.canonical_id or null;
    namespace =
      if canonical == null
      then null
      else lib.head (lib.splitString "/" canonical);
  in
    (identity (
      if namespace == "zhipuai"
      then "zhipu"
      else namespace
    ) "cliproxyapi:opencodeGo.models.${id}")
    // (goMakerFacts.${id} or {})
    // {
      aliases.opencode-go = lib.optional (canonical != null) canonical;
    })
  opencodeGo.models;
  defaults = {
    models =
      native "anthropic" "claude-code:models" claude
      // native "openai" "chatgpt-codex:models" (map (model: model.slug) codex)
      // native "zhipu" "cliproxyapi:zAi.models" zAi.models
      // goModels;
    providers = {
      claude.maker = "anthropic";
      codex.maker = "openai";
    };
  };
  sorted = values: lib.sort builtins.lessThan (lib.unique values);
  credentialBindings = pools: reachable:
    lib.unique (lib.concatMap (pool:
      lib.mapAttrsToList (_: credential: credential // {inherit pool;}) pools.${pool}.credentials)
    reachable);
  resolve = {
    models ? defaults.models,
    pools ? {},
    providers ? defaults.providers,
    runtimes ? {},
    runtimeModels ? {},
  }: let
    # Resolve all exact aliases before comparing offers; ambiguity cannot be
    # hidden by map insertion order, even when a canonical name is an alias.
    spellings = lib.concatLists (lib.mapAttrsToList (id: model:
      map (alias: {inherit alias id;}) ([id] ++ lib.concatLists (builtins.attrValues (model.aliases or {}))))
    models);
    aliases = lib.groupBy (entry: entry.alias) spellings;
    canonical = name: let
      ids = sorted (map (entry: entry.id) (aliases.${name} or []));
    in
      if ids == []
      then throw "ai.catalog: unknown model ${builtins.toJSON name}."
      else if lib.length ids != 1
      then throw "ai.catalog: ambiguous model alias ${builtins.toJSON name}: ${lib.concatStringsSep ", " ids}."
      else lib.head ids;
    normalized =
      lib.mapAttrs (_: pool: {
        credentials = pool.credentials or {};
        models = sorted (map canonical (pool.models or []));
        providerCatalogs = sorted (map (provider:
          if providers ? ${provider}
          then provider
          else throw "ai.catalog: unknown provider catalog ${builtins.toJSON provider}.") (pool.providerCatalogs or []));
      })
      pools;
    reach = lib.mapAttrs (_: runtime:
      sorted (map (pool:
        if normalized ? ${pool}
        then pool
        else throw "ai.catalog: unknown pool ${builtins.toJSON pool}.")
      runtime.pools))
    runtimes;
    maker = id: models.${id}.maker or null;
    openOffers = pool: id: lib.any (provider: providers.${provider}.maker == maker id) normalized.${pool}.providerCatalogs;
    finiteOffers = runtime: pool: map canonical (runtimeModels.${runtime}.${pool} or normalized.${pool}.models);
    offers = runtime: pool: id: lib.elem id (finiteOffers runtime pool) || openOffers pool id;
    diagnostic = runtime: model: owners: reason: ''ai.catalog: runtime "${runtime}" offers model "${model}" from multiple pools: ${lib.concatStringsSep ", " owners}. Select one pool for this model in this runtime. Reason: ${reason}.'';
    conflicts = lib.concatLists (lib.mapAttrsToList (runtime: reachable: let
      finite = sorted (lib.concatMap (finiteOffers runtime) reachable);
      openProviders = sorted (lib.concatMap (pool: normalized.${pool}.providerCatalogs) reachable);
      finiteConflicts = lib.concatMap (id: let
        owners = lib.filter (pool: offers runtime pool id) reachable;
        hasOpen = lib.any (pool: openOffers pool id) owners;
      in
        lib.optional (lib.length owners > 1) {
          model = id;
          message = diagnostic runtime id owners (
            if hasOpen
            then "finite offer intersects an open OAuth catalog"
            else "duplicate finite offers"
          );
        })
      finite;
      openConflicts = lib.concatLists (lib.mapAttrsToList (_: catalogs: let
        provider = lib.head catalogs;
        owners = lib.filter (pool: lib.any (name: lib.elem name catalogs) normalized.${pool}.providerCatalogs) reachable;
      in
        lib.optional (lib.length owners > 1) {
          model = "provider-catalog:${provider}";
          message = diagnostic runtime "provider-catalog:${provider}" owners "the same open OAuth provider catalog is reachable through multiple budgets";
        })
      (lib.groupBy (provider: providers.${provider}.maker) openProviders));
    in
      map (conflict: conflict.message) (lib.sort (a: b: a.model < b.model) (finiteConflicts ++ openConflicts)))
    reach);
    unknownMakers = lib.concatLists (lib.mapAttrsToList (runtime: reachable:
      lib.optionals (lib.any (pool: normalized.${pool}.providerCatalogs != []) reachable)
      (map (id: ''ai.catalog: runtime "${runtime}" cannot compare model "${id}" with an open OAuth catalog: declare its maker.'')
        (sorted (lib.filter (id: maker id == null) (lib.concatMap (finiteOffers runtime) reachable)))))
    reach);
    errors = conflicts ++ unknownMakers;
    # A diagnostic view lets module assertions expose the exact same errors;
    # every consuming projection forces checked, including manual callers.
    checked =
      if errors == []
      then true
      else throw (lib.concatStringsSep "\n" errors);
  in {
    inherit canonical errors;
    providers = builtins.seq checked providers;
    models = builtins.seq checked models;
    pools = builtins.deepSeq (map (entry: canonical entry.alias) spellings) (builtins.seq checked normalized);
    runtimes = builtins.seq checked reach;
    modelsFor = runtime: builtins.seq checked (lib.filter (id: lib.any (pool: offers runtime pool id) (reach.${runtime} or [])) (builtins.attrNames models));
    poolFor = runtime: model:
      builtins.seq checked (let
        owners = lib.filter (pool: offers runtime pool (canonical model)) (reach.${runtime} or []);
      in
        if owners == []
        then null
        else lib.head owners);
    credentialsFor = runtime:
      builtins.seq checked (credentialBindings normalized (reach.${runtime} or []));
  };
in {
  inherit credentialBindings defaults opencodeGo resolve zAi;
}
