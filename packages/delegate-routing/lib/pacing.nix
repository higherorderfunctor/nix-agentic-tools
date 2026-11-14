# Build collection manifests for library callers from evaluated pools and CPA routes.
# CPA supplies offers; module types supply Reader settings and native capacities.
{lib}: {
  cpaRoutes,
  pools,
  techniques,
}: let
  # Scope checks consider every selected client, while output keeps each client's offers.
  allOffers = lib.concatLists (lib.filter (offers: offers != null) (builtins.attrValues cpaRoutes));
  # A collection registration names an offered credential, never a vendor or native pool.
  unknown = lib.filterAttrs (name: pool:
    (pool.limits != {} || (pool.usage != null && pool.usage.readerPool != null))
    && !lib.any (offer: offer.credential == name) allOffers)
  pools;
  # Missing registrations retain offers without making a Reader request.
  registration = offers: credential:
    if !(pools ? ${credential})
    then {
      command = null;
      limits = {};
      readerPool = credential;
    }
    else let
      pool = pools.${credential};
      inherit (pool) usage window;
      readerPool =
        if usage == null
        then null
        else usage.readerPool;
      models = lib.unique (map (offer: offer.id) (lib.filter (offer: offer.credential == credential) offers));
      available = lib.unique (map (offer: offer.id) (lib.filter (offer: offer.credential == credential) allOffers));
      declared = pool.limits;
      scoped = lib.mapAttrs (_: spec:
        spec
        // {
          models =
            if spec.models == null
            then models
            else lib.intersectLists models spec.models;
        })
      declared;
      limits = lib.filterAttrs (_: spec: spec.models != []) scoped;
      usd = lib.any (spec: spec.unit == "USD") (builtins.attrValues limits);
      path = "ai.programs.delegate-routing.pools.${credential}";
    in
      if lib.any (spec: spec.models != null && !lib.all (model: lib.elem model available) spec.models) (builtins.attrValues declared)
      then throw "${path}.limits: models must be canonical credential offers or null."
      else if lib.any (spec: spec.unit == "USD") (builtins.attrValues declared) && (window == null || window.unit != "USD" || lib.any (spec: spec.unit == "USD" && spec.window != "monthly") (builtins.attrValues declared))
      then throw "${path}.limits: USD limits must use the existing monthly USD window."
      # Only the accounted Reader accepts monthly budget transport arguments.
      else if usd && readerPool != null && usage.technique != "anthropic-api-usage"
      then throw "${path}.limits: USD transport requires the accounted Reader (anthropic-api-usage)."
      else {
        inherit limits;
        readerPool =
          if readerPool == null
          then credential
          else readerPool;
        command =
          if readerPool == null || limits == {}
          then null
          else techniques.${usage.runtime}.${usage.technique}.command + lib.optionalString usd " --limit ${toString window.limit} --reset-day ${toString window.resetDay} --time-zone UTC --pool ${lib.escapeShellArg readerPool}";
      };
in
  if unknown != {}
  then throw "ai.programs.delegate-routing.pools: collection registrations must name selected CPA credentials (<instance>/<credential>)."
  else
    lib.mapAttrs (runtime: offers: {
      inherit runtime;
      pools = lib.genAttrs (lib.unique (map (offer: offer.credential) offers)) (registration offers);
      # Overlapping offers remain distinct; collection never picks a launch credential.
      routes = map (offer: {inherit (offer) id maker model;}) offers;
    }) (lib.filterAttrs (_: offers: offers != null) cpaRoutes)
