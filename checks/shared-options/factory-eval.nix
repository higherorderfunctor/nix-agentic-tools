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
