# End-to-end module contracts; the shared harness discovers every backend.
{
  harness,
  pkgs,
  self,
  ...
}: let
  inherit (harness) checkRows evalHm hmLib mkTest;
in {
  checks.module-context7-shared-mcp-pool-accepted = mkTest "context7-shared-mcp-pool-accepted" (
    let
      server = self.lib.ai.mcpServers.mkContext7 {
        lib = hmLib;
        inherit pkgs;
      } {};
      # Read the shared option to force its merge with Claude loaded, not to
      # check Claude's fanout (covered in checks/ai-factory/factory-eval.nix).
      pool =
        (evalHm {
          ai.claude.enable = true;
          ai.mcpServers.ctx = server;
        }).config.ai.mcpServers;
      merged = pool.ctx;
    in
      checkRows "Context7 defaults in the shared Home Manager MCP pool" {
        "default command names the Context7 executable" = merged.command == "context7-mcp";
        "default entry does not inject command-line arguments" = merged.args == [];
        "default package is the Context7 build, not a generic substitute" = toString merged.package == toString pkgs.ai.mcpServers.context7-mcp;
        "default transport is explicit stdio, not inferred" = merged.type == "stdio";
      }
  );
}
