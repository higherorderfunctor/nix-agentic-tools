# Factory contracts for this owner or shared primitive.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (import ../../lib/testing/factory-harness.nix {inherit lib pkgs harness;}) ai mkTest;
  inherit (harness) checkRows rejectsChange;
  evaluate = config: lib.evalModules {modules = [ai.sharedOptions {inherit config;}];};
  readEffort = value: (evaluate {ai.settings.reasoningEffort = value;}).config.ai.settings.reasoningEffort;
  unset = evaluate {};
in {
  checks = {
    # ── sharedOptions tests ─────────────────────────────────────────
    factory-sharedOptions-accepts-mcpServer-entry = mkTest "sharedOptions-accepts-mcpServer-entry" (
      let
        evaluated = evaluate {
          ai.mcpServers.test = {
            command = "/fixture/bin/hello";
            type = "stdio";
          };
        };
        servers = evaluated.config.ai.mcpServers;
      in
        checkRows "shared MCP server" {
          "only the declared server is present" = builtins.attrNames servers == ["test"];
          "the stdio command is preserved" = servers.test.command == "/fixture/bin/hello";
          "the transport remains stdio" = servers.test.type == "stdio";
        }
    );

    factory-sharedOptions-empty-defaults = mkTest "sharedOptions-empty-defaults" (
      checkRows "unset shared pools" {
        "MCP servers are empty" = unset.config.ai.mcpServers == {};
        "rules are empty" = unset.config.ai.rules == {};
        "skills are empty" = unset.config.ai.skills == {};
      }
    );

    factory-sharedOptions-reasoning-effort-is-portable-intersection = mkTest "sharedOptions-reasoning-effort-is-portable-intersection" (
      let
        rejectsNativeEffort = invalid:
          rejectsChange readEffort {
            inherit invalid;
            expected = "xhigh";
            valid = "xhigh";
          };
      in
        checkRows "portable reasoning effort" {
          "high is preserved" = readEffort "high" == "high";
          "low is preserved" = readEffort "low" == "low";
          "max is outside the portable enum" = rejectsNativeEffort "max";
          "medium is preserved" = readEffort "medium" == "medium";
          "null explicitly unsets effort" = readEffort null == null;
          "ultra is outside the portable enum" = rejectsNativeEffort "ultra";
        }
    );

    factory-sharedOptions-settings-nullable = mkTest "sharedOptions-settings-nullable" (
      let
        fields = unset.options.ai.settings.type.getSubOptions [];
      in
        checkRows "unset shared settings" {
          "the inference declaration supplies no selections" = fields.inference.default == {};
          "the public settings resolve to null leaves" =
            unset.config.ai.settings
            == {
              inference = {
                clientKey = null;
                instance = null;
                key = null;
                url = null;
              };
              reasoningEffort = null;
            };
        }
    );
  };
}
