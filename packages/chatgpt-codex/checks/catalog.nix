# Independent input properties catch lost Codex identities, enable gates and conflicting owner defaults.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  # Expected ids come from extraction, not the contribution under test.
  facts = import ../../../lib/extracted/facts.nix {inherit lib;};
  # Read the owner's aggregate separately from the backend module.
  models = facts.get (facts.load {dir = ../extracted;}).aggregate "models";
  # The independent inventory uses record values rather than list indices.
  ids = map (model: model.slug) models;
  # CPA's raw vendor facts independently establish overlapping identities and evidence.
  go = (facts.get (facts.load {dir = ../../cliproxyapi/extracted;}).aggregate "opencodeGo").models;
  # Shared ids must retain both owners' facts without assuming a rotating inventory.
  overlap = lib.filter (id: builtins.hasAttr id go) ids;
  # Real owner discovery exercises both wrapper imports and their transformed bodies.
  backends = {
    devenv = harness.evalDevenvModules;
    hm = harness.evalHmModules;
  };
  # Each runtime state must expose the same static contribution and accept user leaves.
  checks = lib.mapAttrs (backend: evaluate:
    harness.mkTest "chatgpt-codex-catalog-${backend}" (lib.all (enable: let
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
                catalog-test-added = {
                  maker = "openai";
                  source = ["synthetic addition"];
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
      cases = {
        "discarded extracted ids or enable-gated facts" = lib.all (id:
          builtins.hasAttr id catalog.models
          && catalog.models.${id}.maker == "openai"
          && lib.elem "chatgpt-codex:models" catalog.models.${id}.source)
        ids;
        "lost CPA overlap evidence" = lib.all (id:
          lib.elem "cliproxyapi:opencodeGo.models.${id}" catalog.models.${id}.source)
        overlap;
        "user addition lost or maker-wide offer narrowed" =
          configured.models.catalog-test-added.maker
          == "openai"
          && configured.vendors.codex
          == {
            maker = "openai";
            models = null;
          };
        "user leaf overrides lost" =
          configured.models.${chosen}.maker
          == "configured-maker"
          && configured.models.${chosen}.source == ["configured evidence"];
        "vendor default cannot be overridden" = vendorOverride.maker == "configured-maker" && vendorOverride.models == null;
        "vendor narrowed to extracted inventory" =
          catalog.vendors.codex
          == {
            maker = "openai";
            models = null;
          };
      };
      failures = builtins.attrNames (lib.filterAttrs (_: ok: !ok) cases);
    in
      lib.assertMsg (failures == []) "${backend}, enable=${lib.boolToString enable}: ${lib.concatStringsSep "; " failures}") [false true]))
  backends;
in {
  # One owner check covers both backend imports without pinning model ids.
  checks.chatgpt-codex-catalog = pkgs.linkFarm "chatgpt-codex-catalog" (lib.mapAttrsToList (name: path: {inherit name path;}) checks);
}
