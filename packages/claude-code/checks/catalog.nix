# Independent inventories catch missing Claude imports, gated identities and broken owner merging.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  # Expectations read extraction directly, never the contribution under test.
  facts = import ../../../lib/extracted/facts.nix {inherit lib;};
  # The aggregate's set value is a list, not an attribute set of model records.
  ids = facts.get (facts.load {dir = ../extracted;}).aggregate "models";
  # CPA's independent input establishes overlapping identities and evidence.
  go = (facts.get (facts.load {dir = ../../cliproxyapi/extracted;}).aggregate "opencodeGo").models;
  # Select an override target from current input so release changes need no fixture edits.
  chosen = lib.head ids;
  # Lists merge without promising order.
  sorted = values: lib.sort builtins.lessThan (lib.unique values);
  # An isolated evaluation detects extra or discarded ids without other owners masking them.
  isolated =
    (lib.evalModules {
      modules = [../../ai-module/modules/catalog.nix ../modules/catalog.nix];
    }).config.ai.catalog;
  # Real backend imports exercise both wrappers and CPA coexistence.
  backends = {
    devenv = harness.evalDevenvModules;
    hm = harness.evalHmModules;
  };
  # Ordinary definitions must override defaults at individual leaves.
  configured.ai.catalog = {
    models = {
      ${chosen} = {
        maker = "configured-maker";
        source = ["configured evidence"];
      };
      catalog-test-added = {
        maker = "anthropic";
        source = ["configured addition"];
      };
    };
  };
  # Test enabled and disabled production option shapes with the same identity expectations.
  checks = lib.mapAttrs (backend: evaluate:
    harness.mkTest "claude-code-catalog-${backend}" (let
      catalogs = map (enable: (evaluate [{ai.claude.enable = enable;}]).config.ai.catalog) [false true];
      changed = (evaluate [configured]).config.ai.catalog;
      vendorOverride = (evaluate [{ai.catalog.vendors.claude.maker = "configured-maker";}]).config.ai.catalog;
      cases = {
        "aggregate set misread or owner ids discarded" = builtins.isList ids && sorted (builtins.attrNames isolated.models) == sorted ids;
        "missing backend import or enable-gated facts" = lib.all (catalog:
          lib.all (id: catalog.models ? ${id} && catalog.models.${id}.maker == "anthropic" && lib.elem "claude-code:models" catalog.models.${id}.source) ids)
        catalogs;
        "shared CPA identity or evidence overwritten" = lib.all (catalog:
          lib.all (id: let
            identity = catalog.models.${id};
          in
            lib.elem "cliproxyapi:opencodeGo.models.${id}" identity.source)
          (lib.filter (id: go ? ${id}) ids))
        catalogs;
        "user addition lost or maker-wide offer narrowed" = changed.models.catalog-test-added.maker == "anthropic" && changed.models.catalog-test-added.source == ["configured addition"] && changed.vendors.claude.maker == "anthropic" && changed.vendors.claude.models == null;
        "user leaf override blocked by owner priority" = changed.models.${chosen}.maker == "configured-maker" && changed.models.${chosen}.source == ["configured evidence"];
        "vendor leaf override blocked by owner priority" = vendorOverride.vendors.claude.maker == "configured-maker";
        "vendor offer is finite or runtime-gated" = lib.all (catalog: catalog.vendors.claude.maker == "anthropic" && catalog.vendors.claude.models == null) catalogs;
      };
      failures = builtins.attrNames (lib.filterAttrs (_: ok: !ok) cases);
    in
      lib.assertMsg (failures == []) "${backend}: ${lib.concatStringsSep "; " failures}"))
  backends;
in {
  # A single owner property check covers both backends without rotating model literals.
  checks.claude-code-catalog = pkgs.linkFarm "claude-code-catalog" (lib.mapAttrsToList (name: path: {inherit name path;}) checks);
}
