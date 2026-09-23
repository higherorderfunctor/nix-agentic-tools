# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode sembleignore
{
  pkgs,
  harness,
  ...
}: let
  inherit (harness) evalHm hmLib mkTest;
in {
  checks = {
    # Matches the module-claude-shared-mcp-pool-accepted naming precedent:
    # this test verifies the shared ai.mcpServers pool ACCEPTS a context7
    # entry alongside a loaded claude module without type conflicts. It
    # does NOT verify the claude module's internal mergedServers fanout
    # computation — that's covered in checks/ai-factory/factory-eval.nix via the
    # factory-mkRuntime-fanout-* tests.
    module-context7-shared-mcp-pool-accepted = mkTest "context7-shared-mcp-pool-accepted" (
      let
        evaluated = evalHm {
          ai.claude.enable = true;
          ai.mcpServers.ctx = {
            type = "stdio";
            package = pkgs.ai.mcpServers.context7-mcp or pkgs.hello;
            command = "context7-mcp";
          };
        };
      in
        evaluated.config.ai.mcpServers ? ctx
    );

    module-context7-factory-call = mkTest "context7-factory-call" (
      let
        mkContext7 = import ../lib/mkContext7.nix;
        result = mkContext7 {
          lib = hmLib;
          pkgs = pkgs // {ai = pkgs.ai or {};};
        } {};
      in
        result.type == "stdio"
    );
  };
}
