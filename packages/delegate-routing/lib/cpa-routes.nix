# Project CPA's computed client routes into secret-free concrete launch offers.
# CPA owns API selection and filtering; the catalog supplies launch identities.
{
  lib,
  catalog,
  servedModels,
  instances ? {},
  inferenceInstances ? {},
  selections ? {},
}: let
  # Canonicalization preserves vendor-scoped aliases without resolving routes again.
  providers = import ../../cliproxyapi/lib/providers.nix {inherit lib catalog servedModels;};
  # A runtime sees only the credentials exported for its selected CPA client.
  project = runtime: selection: let
    instance = instances.${selection.instance} or null;
    offers = route: let
      credential = instance.credentials.${route.name};
      vendor =
        if credential.oauth != null
        then credential.oauth.vendor
        else credential.vendor;
      declared = catalog.vendors.${vendor}
        or (throw "ai.${runtime}.settings.inference: OAuth credential `${route.name}` names vendor `${vendor}`, which is absent from ai.catalog.vendors.");
      # OAuth grants cover the maker, never a finite vendor model list.
      ids =
        if credential.oauth == null
        then route.models
        else builtins.attrNames (lib.filterAttrs (_: model: declared.maker != null && model.maker == declared.maker) catalog.models);
      offer = model: let
        canonical = providers.canonical vendor model;
      in
        if canonical.errors != []
        then throw (lib.concatStringsSep "; " canonical.errors)
        else {
          inherit model;
          inherit (canonical) id;
          maker = catalog.models.${canonical.id}.maker or null;
        };
    in
      map offer ids;
  in
    if selection.instance == null || instance == null
    then null
    else lib.concatMap offers inferenceInstances.${selection.instance}.clients.${selection.clientKey}.credentials;
in
  lib.mapAttrs project selections
