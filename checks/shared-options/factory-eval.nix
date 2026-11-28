# Factory contracts for this owner or shared primitive.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (import ../../lib/testing/factory-harness.nix {inherit lib pkgs harness;}) ai mkTest;
  inherit (harness) checkRows rejectsChange;
  evaluate = configs: lib.evalModules {modules = [ai.sharedOptions] ++ map (config: {inherit config;}) configs;};
  readEffort = value: (evaluate [{ai.settings.reasoningEffort = value;}]).config.ai.settings.reasoningEffort;
in {
  checks = {
    # ── sharedOptions tests ─────────────────────────────────────────
    factory-sharedOptions-accepts-mcpServer-entry = mkTest "sharedOptions-accepts-mcpServer-entry" (
      let
        evaluated = evaluate [
          {
            ai.mcpServers.test = {
              command = "/fixture/bin/hello";
              type = "stdio";
            };
          }
        ];
        servers = evaluated.config.ai.mcpServers;
      in
        checkRows "shared MCP server" {
          "explicit stdio is not replaced by the null transport default" = servers.test.type == "stdio";
        }
    );

    factory-sharedOptions-reasoning-effort-is-portable-intersection = mkTest "sharedOptions-reasoning-effort-is-portable-intersection" (
      checkRows "portable reasoning effort" {
        "a higher-priority null clears a configured root effort" =
          (evaluate [
            {ai.settings.reasoningEffort = lib.mkDefault "high";}
            {ai.settings.reasoningEffort = null;}
          ]).config.ai.settings.reasoningEffort
          == null;
        "max is rejected as a runtime-specific effort" = rejectsChange readEffort {
          expected = "xhigh";
          invalid = "max";
          valid = "xhigh";
        };
        "medium is not dropped from the portable root enum" = readEffort "medium" == "medium";
      }
    );
  };
}
