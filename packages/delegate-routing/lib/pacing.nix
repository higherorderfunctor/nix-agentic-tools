# Bind allowance inspection to direct CPA offers and the existing Reader registry.
{lib}: {
  cpaRoutes,
  pools,
  techniques,
}: let
  # Collect credential offers across every selected runtime client.
  allOffers = lib.concatLists (lib.filter (offers: offers != null) (builtins.attrValues cpaRoutes));
  # Preview opt-ins must name an actual credential, not a vendor or old native pool.
  unknown = lib.filterAttrs (name: pool:
    ((pool.limits or {}) != {} || ((pool.usage or null) != null && (pool.usage.readerPool or null) != null))
    && !lib.any (offer: offer.credential == name) allOffers)
  pools;
  # One registration consumes the existing runtime/technique and USD budget.
  registration = offers: credential: let
    pool = pools.${credential} or {};
    usage = pool.usage or null;
    readerPool =
      if usage == null
      then null
      else usage.readerPool or null;
    node =
      if usage == null
      then null
      else techniques.${usage.runtime}.${usage.technique} or null;
    models = lib.unique (map (offer: offer.id) (lib.filter (offer: offer.credential == credential) offers));
    available = lib.unique (map (offer: offer.id) (lib.filter (offer: offer.credential == credential) allOffers));
    declared = pool.limits or {};
    window = pool.window or null;
    usd = lib.any (spec: spec.unit == "USD") (builtins.attrValues limits);
    path = "ai.programs.delegate-routing.pools.${credential}";
    scoped = lib.mapAttrs (_: spec:
      spec
      // {
        capacity =
          if spec.unit == "USD" && window != null
          then window.limit
          else spec.capacity;
        models =
          if spec.models == null
          then models
          else lib.intersectLists models spec.models;
      })
    declared;
    limits = lib.filterAttrs (_: spec: spec.models != []) scoped;
  in
    if lib.any (spec: spec.models != null && (spec.models == [] || !lib.all (model: lib.elem model available) spec.models)) (builtins.attrValues declared)
    then throw "${path}.limits: models must be nonempty canonical credential offers or null."
    else if !lib.allUnique (map (spec: spec.window) (builtins.attrValues declared))
    then throw "${path}.limits: register each Reader window once."
    else if lib.any (spec: spec.unit == "USD") (builtins.attrValues declared) && (window == null || window.unit != "USD" || lib.any (spec: spec.unit == "USD" && ((spec.capacity or window.limit) != window.limit || spec.window != "monthly")) (builtins.attrValues declared))
    then throw "${path}.limits: USD limits must use the existing monthly USD window and capacity."
    else if usd && readerPool != null && usage.technique != "anthropic-api-usage"
    then throw "${path}.limits: USD transport requires the accounted Reader (anthropic-api-usage)."
    # Manual mkObservation callers do not pass through the module's assertions.
    else if readerPool != null && (node == null || !node.enable || node.kind != "usage" || node.command == null || lib.trim node.command == "")
    then throw "${path}.usage.technique: reference an enabled usage technique with a non-empty command."
    else {
      inherit limits;
      # A missing label never infers a provider; no capture is attempted.
      readerPool =
        if readerPool == null
        then credential
        else readerPool;
      command =
        if readerPool == null || limits == {}
        then null
        else node.command + lib.optionalString usd " --limit ${toString window.limit} --reset-day ${toString window.resetDay} --time-zone UTC --pool ${lib.escapeShellArg readerPool} --now-ms <now-ms>";
    };
in
  if unknown != {}
  then throw "ai.programs.delegate-routing.pools: allowance preview registrations must name selected CPA credentials (<instance>/<credential>)."
  else
    lib.mapAttrs (runtime: offers: {
      inherit runtime;
      pools = lib.genAttrs (lib.unique (map (offer: offer.credential) offers)) (registration offers);
      # Preserve overlap without selecting a measured credential for a launch.
      routes = map (offer: {inherit (offer) id maker model;}) offers;
    }) (lib.filterAttrs (_: offers: offers != null) cpaRoutes)
