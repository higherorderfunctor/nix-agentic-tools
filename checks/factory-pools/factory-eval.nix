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
      checkRoot = value: value.description == "root" && value.instructions.text == "root" && value.tools == ["Read"];
      checkRuntime = value: value.description == "runtime" && value.tools == null;
      regression = "agent null does not retract the root agent, or replacement loses its description or inherits root tools";
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
      regression = "launcher variable null does not retract the root value, or the root value wins over a local value";
      rootValue = "root";
      runtimeValue = "runtime";
    };
    mcpServers = {
      checkRoot = value: value.command == "root-mcp" && value.args == ["--root-only"];
      checkRuntime = value: value.args == [];
      regression = "lowering loses the server null, or the replacement command inherits root arguments";
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
      checkRuntime = value: value.matcher == null;
      regression = "a disabled local rule leaves the root rule active, or replacement inherits the root matcher";
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
      # Codex checks runtime skill replacement; keep the override here to
      # verify that it does not change the sibling runtime's value.
      checkRuntime = _: true;
      regression = "a skill null leaves the root path active";
      rootValue = rootFixture;
      runtimeValue = runtimeFixture;
    };
  };
in {
  checks.factory-pool-negation = mkTest "pool-negation" (
    # Observe the callback inputs so each row checks its factory call site,
    # not a module option's type or a runtime's renderer. Runtime A must retain
    # the untouched key and runtime B must retain the root values at both keys
    # changed by A.
    checkRows "runtime-local suppression and replacement"
    (lib.mapAttrs' (poolName: {regression, ...} @ row:
      lib.nameValuePair "${poolName}: ${regression}; or the untouched entry or either sibling entry fails to retain its root value"
      (poolMergeContract ((removeAttrs row ["regression"]) // {inherit poolName;})))
    pools)
  );
}
