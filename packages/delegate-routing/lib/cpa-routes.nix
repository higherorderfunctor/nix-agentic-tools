# Project selected CPA client routes for inspection and concrete launch selection.
# Credentials stay with CPA; these records contain identities, never key material.
{
  lib,
  catalog,
  instances ? {},
  selections ? {},
}: let
  # Reuse CPA's API choice, filtered model offers and vendor-scoped aliases.
  providers = import ../../cliproxyapi/lib/providers.nix {inherit lib catalog;};
  # One runtime sees only its selected client's routes; absent CPA data is unknown.
  project = runtime: selection: let
    instance = instances.${selection.instance} or null;
    client = instance.clientKeys.${selection.clientKey} or null;
    path = "ai.${runtime}.settings.inference";
    # Resolve each route independently so optional overlap retains every offer.
    offers = choice: let
      routed = providers.route instance path choice;
      credential = instance.credentials.${choice.credential};
      vendor =
        if credential.oauth != null
        then credential.oauth.vendor
        else credential.vendor;
      declared =
        catalog.vendors.${vendor}
        or (throw "${path}: OAuth credential `${choice.credential}` names vendor `${vendor}`, which is absent from ai.catalog.vendors.");
      ids =
        routed.models or (
          if declared.models != null
          then declared.models
          else builtins.attrNames (lib.filterAttrs (_: model: model.maker == declared.maker) catalog.models)
        );
      offer = spelling: let
        model =
          if builtins.isAttrs spelling
          then lib.defaultTo spelling.name spelling.alias
          else spelling;
        canonical = providers.canonical vendor (
          if builtins.isAttrs spelling
          then spelling.name
          else spelling
        );
      in
        if canonical.errors != []
        then throw (lib.concatStringsSep "; " canonical.errors)
        else {
          inherit model vendor;
          inherit (choice) credential;
          inherit (selection) instance;
          api = routed.api or null;
          inherit (canonical) id;
          maker = catalog.models.${canonical.id}.maker or null;
        };
    in
      if routed ? problem
      then throw routed.problem
      else map offer ids;
  in
    if selection.instance == null || instance == null
    then null
    # Standalone importers must also refuse a disabled selected CPA instance.
    else if !instance.enable
    then throw "${path}: selected CPA instance is disabled."
    # Standalone importers must also refuse a missing or undeclared CPA clientKey.
    else if selection.clientKey == null || client == null
    then throw "${path}: select a declared CPA clientKey."
    else lib.concatMap offers client.routes;
in
  lib.mapAttrs project selections
