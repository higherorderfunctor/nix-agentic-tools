# Deliver every selected client's offers alongside the Readers that can measure them.
# Only public launch identities and the registered technique command enter the manifest.
{
  lib,
  cpaRoutes,
  credentialUsage,
  runtime,
  techniques,
}: let
  allRoutes = lib.concatLists (lib.mapAttrsToList (runtime: offers:
    map (offer: {
      inherit runtime;
      inherit (offer) id maker model;
      # Manual builders can supply model offers without CPA attribution.
      instance = offer.instance or null;
      credential = offer.credential or null;
    })
    offers) (lib.filterAttrs (_: offers: offers != null) cpaRoutes));
  routes = builtins.filter (route: route.runtime == runtime) allRoutes;
  byCredential = offers:
    lib.groupBy (offer: "${offer.instance}/${offer.credential}")
    (builtins.filter (offer: offer.instance != null && offer.credential != null) offers);
  available = byCredential allRoutes;
  local = byCredential routes;
  registration = name: settings: let
    inherit (settings) usage;
    technique = techniques.${usage.runtime}.${usage.technique} or null;
    modelIds = offers: lib.unique (map (offer: offer.id) offers);
    models = modelIds local.${name};
    scope = _: limit:
      limit
      // {
        models =
          if limit.models == null
          then models
          else if lib.all (model: lib.elem model (modelIds available.${name})) limit.models
          then lib.intersectLists models limit.models
          else throw "delegate-routing.credentialUsage.${name}.limits: models must be offered by this credential";
      };
    limits = lib.filterAttrs (_: limit: limit.models != []) (lib.mapAttrs scope settings.limits);
  in {
    inherit limits;
    inherit (settings) pin readerPool transport;
    command =
      if usage == null || limits == {}
      then null
      else if technique != null && technique.enable && technique.kind == "usage" && technique.command != null && lib.trim technique.command != ""
      then technique.command
      else throw "delegate-routing.credentialUsage.${name}.usage: select an enabled Reader technique with a command";
  };
in {
  inherit routes;
  readers =
    if lib.subtractLists (builtins.attrNames available) (builtins.attrNames credentialUsage) != []
    then throw "delegate-routing.credentialUsage: registrations must name a selected CPA credential"
    else lib.mapAttrs registration (builtins.intersectAttrs local credentialUsage);
}
