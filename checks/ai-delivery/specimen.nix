# Independent populated declarations at the runtime options' DEFAULT directories.
# The two Kiro strategies share a specimen; only mcpWriteMode varies.
{lib}: {
  modes = ["merge" "overwrite"];
  config = mode: runtime: strategy: {
    ai =
      {
        agents.probe = {
          description = "probe";
          instructions = {text = "probe";};
        };
        context.text = "probe";
        environmentVariables.PROBE = "value";
        hooks.PreToolUse = [{hooks = [{command = "true";}];}];
        lspServers.probe.command = "true";
        mcpServers.probe.command = "true";
        rules.probe.text = "probe";
        rules.scoped = {
          text = "probe scoped";
          matcher = ["*.nix"];
        };
        skills.probe = ../ai-delivery-layer/fixtures/probe-skill;
      }
      // {
        ${runtime} =
          {enable = true;}
          // {
            claude = {
              hookScripts.probe = "true";
              native.settings.model = "probe";
              unpinLaunchEffort.probe = true;
            };
            codex = {
              native.settings.model = "probe";
              execpolicyRules.probe = "prefix_rule(pattern = [\"probe\"], decision = \"allow\")";
            };
            copilot.native.settings.model = "probe";
            kimchi = {
              native.settings = {
                llmEndpoint = "https://example.invalid";
                skillPaths = ["probe"];
              };
              native.harnessSettings.resources.probe = true;
            };
            kiro = {
              agents.probe.prompt = {text = "probe";};
              hooksJson.probe = ''{"event":"pre-commit"}'';
              mcpWriteMode = strategy;
              native.settings =
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
  };
  # A file may carry several input surfaces. This is consumer knowledge;
  # methods and writer names must never enter this classification table.
  surfacesFor = runtime: path:
    if path == ".claude.json"
    then ["settings"]
    else if path == ".claude/settings.json"
    then ["hooks" "permissions" "settings"]
    else if path == ".codex/config.toml"
    then ["mcpServers" "permissions" "settings"]
    else if lib.hasSuffix "/.lsp.json" path || lib.hasSuffix "/lsp-config.json" path || lib.hasSuffix "/lsp.json" path
    then ["lspServers"]
    else if lib.hasSuffix "/.mcp.json" path || lib.hasSuffix "/mcp-config.json" path || lib.hasSuffix "/mcp.json" path
    then ["mcpServers"]
    else if lib.hasInfix "/agents/" path || lib.hasSuffix "/agents" path
    then ["agents"]
    else if lib.hasInfix "/hooks/" path || lib.hasSuffix "/hooks" path || lib.hasSuffix "/hooks.json" path
    then ["hooks"]
    else if lib.hasInfix "/skills/" path || lib.hasSuffix "/skills" path
    then ["skills"]
    else if path == "AGENTS.md" || path == ".codex/AGENTS.md"
    then ["context" "rules"]
    else if lib.hasSuffix "/AGENTS.md" path || lib.hasSuffix "/CLAUDE.md" path || lib.hasSuffix "/copilot-instructions.md" path
    then ["context"]
    else if lib.hasInfix "/rules/" path || lib.hasInfix "/instructions/" path || lib.hasInfix "/steering/" path
    then ["rules"]
    else if lib.hasSuffix "/permissions.yaml" path
    then ["permissions"]
    else if lib.hasSuffix "/settings.json" path || lib.hasSuffix "/config.json" path || lib.hasSuffix "/cli.json" path
    then ["settings"]
    else throw "ai-delivery: unmapped delivery entry ${runtime}/${path}";
}
