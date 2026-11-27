# Factory contracts for this owner or shared primitive.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) checkRows;
  inherit (import ../../lib/testing/factory-harness.nix {inherit lib pkgs harness;}) mkTest poolMergeContract;

  pools = {
    agents = {
      checkRoot = value: value.description == "root" && value.tools == ["Read"];
      checkRuntime = value: value.description == "runtime" && value.tools == null;
      rootValue = {
        description = "root";
        instructions.text = "root";
        tools = ["Read"];
      };
      runtimeValue = {
        description = "runtime";
        instructions.text = "runtime";
      };
    };
    environmentVariables = {
      checkRoot = value: value == "root";
      checkRuntime = value: value == "runtime";
      rootValue = "root";
      runtimeValue = "runtime";
    };
    mcpServers = {
      checkRoot = value: value.command == "root-mcp" && value.args == ["--root-only"];
      checkRuntime = value: value.command == "runtime-mcp" && value.args == [];
      rootValue = {
        args = ["--root-only"];
        command = "root-mcp";
        type = "stdio";
      };
      runtimeValue = {
        command = "runtime-mcp";
        type = "stdio";
      };
    };
    rules = {
      checkRoot = value: value.text == "root" && value.matcher == ["**/*.root"];
      checkRuntime = value: value.text == "runtime" && value.matcher == null;
      rootValue = {
        matcher = ["**/*.root"];
        text = "root";
      };
      runtimeValue.text = "runtime";
      suppressionValue.enable = false;
    };
    skills = let
      rootFixture = ../../packages/claude-code/checks/fixtures/claude-agents;
      runtimeFixture = ../../packages/kiro-cli/checks/fixtures/kiro-steering;
    in {
      checkRoot = value: value == rootFixture;
      checkRuntime = value: value == runtimeFixture;
      rootValue = rootFixture;
      runtimeValue = runtimeFixture;
    };
  };
in {
  checks.factory-pool-negation = mkTest "pool-negation" (
    # Suppression and replacement in one runtime must not affect another.
    checkRows "runtime pool negation and replacement"
    (lib.mapAttrs (poolName: row: poolMergeContract (row // {inherit poolName;})) pools)
  );
}
