# Devenv backend transformer.
#
# Takes a backend-agnostic app record produced by `mkAiApp` and
# returns a devenv module function that writes the appropriate
# `files.*` / `claude.code.*` / `<ecosystem>.*` attributes for the
# devenv backend.
#
# Mirrors `hmTransform.nix` but targets devenv's `files.*` option
# instead of HM's `home.file.*`. The shared `options` from the
# record apply to both backends; `devenv.options` adds
# devenv-specific options.
{lib}: appRecord: {config, ...}: let
  aiCommon = import ../ai-common.nix {inherit lib;};
  cfg = config.ai.${appRecord.name};
  # Collision-as-failure merges — shared ai.<pool> vs ai.<cli>.<pool>.
  # See lib/ai/ai-common.nix:mergeWithCollisionCheck. Assertions are
  # emitted through config.assertions below.
  mergeCheck = poolName: topPool: cliPool:
    aiCommon.mergeWithCollisionCheck {
      inherit poolName topPool cliPool;
      cliName = appRecord.name;
    };
  serversMerge = mergeCheck "mcpServers" config.ai.mcpServers cfg.mcpServers;
  skillsMerge = mergeCheck "skills" config.ai.skills cfg.skills;
  rulesMerge = mergeCheck "rules" config.ai.rules cfg.rules;
  lspMerge = mergeCheck "lspServers" config.ai.lspServers (cfg.lspServers or {});
  envMerge = mergeCheck "environmentVariables" config.ai.environmentVariables (cfg.environmentVariables or {});
  agentsMerge = mergeCheck "agents" config.ai.agents (cfg.agents or {});
  collisionAssertions =
    serversMerge.assertions
    ++ skillsMerge.assertions
    ++ rulesMerge.assertions
    ++ lspMerge.assertions
    ++ envMerge.assertions
    ++ agentsMerge.assertions;
  mergedServers = serversMerge.merged;
  mergedInstructions = config.ai.instructions ++ cfg.instructions;
  mergedSkills = skillsMerge.merged;
  mergedRules = rulesMerge.merged;
  mergedLspServers = lspMerge.merged;
  mergedEnvironmentVariables = envMerge.merged;
  mergedClaudeCopilotAgents = agentsMerge.merged;
  topContext = config.ai.context;

  devenvSpec = appRecord.devenv or {};
  devenvOptions = devenvSpec.options or {};
  devenvDefaults = devenvSpec.defaults or {};
  devenvConfigFn = devenvSpec.config or (_: {});

  defaults = appRecord.defaults or {};
  package = devenvDefaults.package or defaults.package or null;
  outputPath = devenvDefaults.outputPath or defaults.outputPath or null;

  customConfig = devenvConfigFn {
    inherit cfg mergedServers mergedInstructions mergedSkills mergedRules mergedLspServers mergedEnvironmentVariables mergedClaudeCopilotAgents topContext;
  };

  renderedInstructions =
    lib.concatMapStringsSep "\n\n" (
      frag: appRecord.transformers.markdown.render frag
    )
    mergedInstructions;

  hasOutputPath = outputPath != null;
  hasInstructions = mergedInstructions != [];
in {
  options.ai.${appRecord.name} =
    {
      enable = lib.mkEnableOption appRecord.name;
      package = lib.mkOption {
        type = lib.types.package;
        default = package;
        description = "The ${appRecord.name} package.";
      };
      mcpServers = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submoduleWith {
          modules = [(import ../mcpServer/commonSchema.nix)];
        });
        default = {};
        description = "${appRecord.name}-specific MCP servers.";
      };
      instructions = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        default = [];
        description = "${appRecord.name}-specific instructions.";
      };
      rules = lib.mkOption {
        type = lib.types.attrsOf aiCommon.ruleModule;
        default = {};
        description = "${appRecord.name}-specific rules (merged with top-level ai.rules; per-app wins on conflict).";
      };
      skills = lib.mkOption {
        type = lib.types.attrsOf lib.types.path;
        default = {};
        description = "${appRecord.name}-specific skills.";
      };
    }
    // (appRecord.options or {})
    // devenvOptions;

  config = lib.mkMerge (
    [
      {_module.args.aiTransformers = appRecord.transformers;}
      # Collision-as-failure: always evaluate (no mkIf cfg.enable
      # guard) so misconfigurations surface even when the feature
      # is toggled off.
      {assertions = collisionAssertions;}
      (lib.mkIf cfg.enable customConfig)
    ]
    ++ lib.optional hasOutputPath (lib.mkIf (cfg.enable && hasInstructions) {
      files.${outputPath}.text = renderedInstructions;
    })
  );
}
