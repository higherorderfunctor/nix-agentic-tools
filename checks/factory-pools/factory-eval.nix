# Factory contracts for this owner or shared primitive.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (import ../../lib/testing/factory-harness.nix {inherit lib pkgs harness;}) mkTest poolMergeContract;
in {
  checks = {
    factory-pool-agents-negation = mkTest "pool-agents-negation" (poolMergeContract {
      poolName = "agents";
      rootValue = {
        description = "root";
        instructions.text = "root";
        tools = ["Read"];
      };
      runtimeValue = {
        description = "runtime";
        instructions.text = "runtime";
      };
      checkRoot = value:
        value.description == "root" && value.tools == ["Read"];
      checkRuntime = value:
        value.description == "runtime" && value.tools == null;
    });
    factory-pool-environmentVariables-negation = mkTest "pool-environmentVariables-negation" (poolMergeContract {
      poolName = "environmentVariables";
      rootValue = "root";
      runtimeValue = "runtime";
      checkRoot = value: value == "root";
      checkRuntime = value: value == "runtime";
    });
    factory-pool-lspServers-negation = mkTest "pool-lspServers-negation" (poolMergeContract {
      poolName = "lspServers";
      rootValue = {
        command = "root-lsp";
        args = ["--root-only"];
      };
      runtimeValue.command = "runtime-lsp";
      checkRoot = value:
        value.command == "root-lsp" && value.args == ["--root-only"];
      checkRuntime = value:
        value.command == "runtime-lsp" && value.args == ["--stdio"];
    });
    factory-pool-mcpServers-negation = mkTest "pool-mcpServers-negation" (poolMergeContract {
      poolName = "mcpServers";
      rootValue = {
        type = "stdio";
        command = "root-mcp";
        args = ["--root-only"];
      };
      runtimeValue = {
        type = "stdio";
        command = "runtime-mcp";
      };
      checkRoot = value:
        value.command == "root-mcp" && value.args == ["--root-only"];
      checkRuntime = value:
        value.command == "runtime-mcp" && value.args == [];
    });
    factory-pool-rules-negation = mkTest "pool-rules-negation" (poolMergeContract {
      poolName = "rules";
      rootValue = {
        text = "root";
        matcher = ["**/*.root"];
      };
      runtimeValue.text = "runtime";
      suppressionValue.enable = false;
      checkRoot = value:
        value.text == "root" && value.matcher == ["**/*.root"];
      checkRuntime = value:
        value.text == "runtime" && value.matcher == null;
    });
    factory-pool-skills-negation = mkTest "pool-skills-negation" (poolMergeContract {
      poolName = "skills";
      rootValue = ../../packages/claude-code/checks/fixtures/claude-agents;
      runtimeValue = ../../packages/kiro-cli/checks/fixtures/kiro-steering;
      checkRoot = value: value == ../../packages/claude-code/checks/fixtures/claude-agents;
      checkRuntime = value: value == ../../packages/kiro-cli/checks/fixtures/kiro-steering;
    });
  };
}
