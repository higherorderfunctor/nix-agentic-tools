# Populated declarations of every surface for one runtime at its options'
# DEFAULT directories.
{lib}: let
  optionPaths = import ../../lib/ai/option-paths.nix {inherit lib;};
in
  mode: runtime:
    lib.recursiveUpdate (lib.setAttrByPath (optionPaths.enable runtime) true) {
      ai =
        {
          agents.probe = {
            description = "probe";
            instructions = {text = "probe";};
          };
          context.text = "probe";
          environmentVariables.PROBE = "value";
          hooks.PreToolUse = [{hooks = [{command = "true";}];}];
          mcpServers.probe.command = "true";
          rules.probe.text = "probe";
          rules.scoped = {
            text = "probe scoped";
            matcher = ["*.nix"];
          };
          skills.probe = ../../packages/ai-module/checks/fixtures/probe-skill;
        }
        // {
          ${runtime} =
            {
              claude = {
                hookScripts.probe = "true";
                native.settings.model = "probe";
                unpinLaunchEffort.probe = true;
              };
              codex = {
                native.settings.model = "probe";
                execpolicyRules.probe = "prefix_rule(pattern = [\"probe\"], decision = \"allow\")";
              };
              copilot = {};
              kimchi = {
                native.settings = {
                  llmEndpoint = "https://example.invalid";
                  region = "us";
                  skillPaths = ["probe"];
                };
                # `resources` is user-scope-only; devenv rejects it.
                native.harnessSettings =
                  if mode == "hm"
                  then {resources.probe = true;}
                  else {hideThinkingBlock = true;};
                permissions.allow = ["probe"];
              };
              kiro = {
                native.agents.probe.prompt = {text = "probe";};
                hooksJson.probe = ''{"event":"pre-commit"}'';
                cli.native.settings =
                  if mode == "hm"
                  then {chat.defaultModel = "probe";}
                  else {chat.enableTangentMode = true;};
                permissions = [
                  {
                    capability = "mcp";
                    effect = "allow";
                    match = ["probe/*"];
                  }
                ];
              };
            }.${
              runtime
            };
        };
    }
