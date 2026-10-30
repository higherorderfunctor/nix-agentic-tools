# Factory contracts for this owner or shared primitive.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (import ../../lib/testing/factory-harness.nix {inherit lib pkgs harness;}) ai mkTest;
in {
  checks = {
    # ── sharedOptions tests ─────────────────────────────────────────
    factory-sharedOptions-empty-defaults = mkTest "sharedOptions-empty-defaults" (
      let
        evaluated = lib.evalModules {
          modules = [
            ai.sharedOptions
            {config = {};}
          ];
        };
      in
        evaluated.config.ai.mcpServers
        == {}
        && evaluated.config.ai.rules == {}
        && evaluated.config.ai.settings.reasoningEffort == null
        && evaluated.config.ai.skills == {}
    );

    factory-sharedOptions-settings-nullable = mkTest "sharedOptions-settings-nullable" (
      let
        evaluated = lib.evalModules {modules = [ai.sharedOptions];};
        fields = builtins.removeAttrs (evaluated.options.ai.settings.type.getSubOptions []) ["_module"];
        fieldNames = (import ../../lib/ai/ai-common.nix {inherit lib;}).normalizedSettingsFields;
        nullOrName = (lib.types.nullOr lib.types.str).name;
      in
        fields
        != {}
        && lib.all (field: let
          option = fields.${field};
        in
          option.default
          == null
          && option.type.name == nullOrName
          && evaluated.config.ai.settings.${field} == null)
        fieldNames
    );

    factory-sharedOptions-reasoning-effort-is-portable-intersection = mkTest "sharedOptions-reasoning-effort-is-portable-intersection" (
      let
        accepts = value:
          (builtins.tryEval
            (lib.evalModules {
              modules = [
                ai.sharedOptions
                {config.ai.settings.reasoningEffort = value;}
              ];
            }).config.ai.settings.reasoningEffort)
        .success;
      in
        accepts "low"
        && accepts "medium"
        && accepts "high"
        && accepts "xhigh"
        && !(accepts "max")
        && !(accepts "ultra")
    );

    factory-sharedOptions-accepts-mcpServer-entry = mkTest "sharedOptions-accepts-mcpServer-entry" (
      let
        evaluated = lib.evalModules {
          modules = [
            ai.sharedOptions
            {
              config.ai.mcpServers.test = {
                type = "stdio";
                package = pkgs.hello;
                command = "hello";
              };
            }
          ];
        };
      in
        evaluated.config.ai.mcpServers.test.type == "stdio"
    );
  };
}
