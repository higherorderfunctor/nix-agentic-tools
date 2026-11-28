# Independent input properties catch lost Codex identities, enable gates and conflicting owner defaults.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) checkRows mkTest;
  # Expected ids come from extraction, not the contribution under test.
  facts = import ../../../lib/extracted/facts.nix {inherit lib;};
  # Read the owner's aggregate separately from the backend module.
  models = facts.get (facts.load {dir = ../extracted;}).aggregate "models";
  # The independent inventory uses record values rather than list indices.
  ids = map (model: model.slug) models;
  # CPA's raw vendor facts independently establish overlapping identities and evidence.
  go = facts.get (facts.load {dir = ../../cliproxyapi/extracted;}).aggregate "opencodeGo";
  # Shared ids must retain both owners' facts without assuming a rotating inventory.
  overlap = lib.filter (id: (go.models.${id}.type or null) == "chat") ids;
  # Real owner discovery exercises both wrapper imports and their transformed bodies.
  backends = {
    devenv = harness.evalDevenvModules;
    hm = harness.evalHmModules;
  };
  # Each runtime state must expose the same static contribution and accept user leaves.
  checks = lib.mapAttrs (backend: evaluate:
    mkTest "chatgpt-codex-catalog-${backend}" (lib.all (enable: let
      base = {ai.codex.enable = enable;};
      catalog = (evaluate [base]).config.ai.catalog;
      chosen = lib.head ids;
      configured =
        (evaluate [
          base
          {
            ai.catalog = {
              models = {
                ${chosen} = {
                  maker = "configured-maker";
                  source = ["configured evidence"];
                };
              };
            };
          }
        ]).config.ai.catalog;
      vendorOverride =
        (evaluate [
          base
          {
            ai.catalog.vendors.codex.maker = "configured-maker";
          }
        ]).config.ai.catalog.vendors.codex;
      makerWideOffer = {
        maker = "openai";
        models = null;
      };
    in
      checkRows "${backend}, enable=${lib.boolToString enable}" {
        "Codex inventory changes with runtime enablement or loses attribution" =
          lib.filter (id: lib.elem "chatgpt-codex:models" catalog.models.${id}.source) (builtins.attrNames catalog.models)
          == lib.sort builtins.lessThan ids
          && lib.all (id: catalog.models.${id}.maker == "openai") ids;
        "configured model leaves are replaced by owner defaults" =
          configured.models.${chosen}.maker
          == "configured-maker"
          && configured.models.${chosen}.source == ["configured evidence"];
        "CPA overlap loses its second evidence source" = lib.all (id:
          lib.elem "cliproxyapi:opencodeGo.models.${id}" catalog.models.${id}.source)
        overlap;
        "vendor default maker is not overridden" = vendorOverride.maker == "configured-maker";
        "vendor offer is narrowed to the extracted inventory" = catalog.vendors.codex == makerWideOffer;
      }) [false true]))
  backends;
in {
  # One owner check covers both backend imports without pinning model ids.
  checks.chatgpt-codex-catalog = pkgs.linkFarm "chatgpt-codex-catalog" (lib.mapAttrsToList (name: path: {inherit name path;}) checks);
}
