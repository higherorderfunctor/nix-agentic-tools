# HM backend transformer.
#
# Takes a backend-agnostic app record produced by `mkAiApp` and
# returns a home-manager module function that writes the appropriate
# `home.file.*` / `home.activation.*` / `programs.*` attributes for
# the HM backend.
#
# Input record shape (from mkAiApp):
#   {
#     name;
#     transformers;
#     defaults ? {package, outputPath?};
#     options ? {};          # shared across backends
#     hm ? {
#       options ? {};        # HM-only option additions
#       defaults ? {};       # HM-only default overrides
#       config ? _: {};      # consumer callback: {cfg, mergedServers, mergedInstructions, mergedSkills} → module attrs
#     };
#     devenv ? { ... };      # ignored by this transformer
#   }
#
# Returns: a module function `{config, ...}: { options; config; }`
# that can be imported into `lib.evalModules` alongside
# `lib/ai/sharedOptions.nix`.
{lib}: appRecord: {config, ...}: let
  aiCommon = import ../ai-common.nix {inherit lib;};
  dirHelpers = import ../dir-helpers.nix {inherit lib;};
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

  hmSpec = appRecord.hm or {};
  hmOptions = hmSpec.options or {};
  hmDefaults = hmSpec.defaults or {};
  hmConfigFn = hmSpec.config or (_: {});

  defaults = appRecord.defaults or {};
  package = hmDefaults.package or defaults.package or null;
  outputPath = hmDefaults.outputPath or defaults.outputPath or null;

  customConfig = hmConfigFn {
    inherit cfg config mergedServers mergedInstructions mergedSkills mergedRules mergedLspServers mergedEnvironmentVariables mergedClaudeCopilotAgents topContext;
  };

  # Baseline render — concatenate rendered instructions into one
  # file at defaults.outputPath. Per-instruction rule files are
  # handled by the consumer config callback if needed.
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
        description = "${appRecord.name}-specific MCP servers (merged with top-level ai.mcpServers; per-app wins on conflict).";
      };
      instructions = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        default = [];
        description = "${appRecord.name}-specific instructions (appended to top-level ai.instructions).";
      };
      rules = lib.mkOption {
        type = lib.types.attrsOf aiCommon.ruleModule;
        default = {};
        description = "${appRecord.name}-specific rules (merged with top-level ai.rules; collisions fail).";
      };
      rulesDir = lib.mkOption {
        type = lib.types.nullOr aiCommon.dirOptionType;
        default = null;
        description = ''
          ${appRecord.name}-specific directory of `.md` rule files. Each
          file becomes one entry in `ai.${appRecord.name}.rules` keyed by
          the basename minus `.md`. Accepts a path literal or
          `{ path, filter? }` (filter: name → bool, default keeps `.md`).
          Runs through the same collision-as-failure merge with
          `ai.rules` as explicit per-CLI entries; other derivations may
          still contribute to the same on-disk rules dir.
        '';
      };
      skills = lib.mkOption {
        type = lib.types.attrsOf lib.types.path;
        default = {};
        description = "${appRecord.name}-specific skills (merged with top-level ai.skills; collisions fail).";
      };
      skillsDir = lib.mkOption {
        type = lib.types.nullOr aiCommon.dirOptionType;
        default = null;
        description = ''
          ${appRecord.name}-specific directory-of-directories; each
          immediate subdirectory becomes one entry in
          `ai.${appRecord.name}.skills` keyed by the subdir name.
          Accepts a path literal or `{ path, filter? }`.
        '';
      };
    }
    // (appRecord.options or {})
    // hmOptions;

  config = lib.mkMerge (
    [
      {_module.args.aiTransformers = appRecord.transformers;}
      # Collision-as-failure: always evaluate (no mkIf cfg.enable
      # guard) so misconfigurations surface even when the feature
      # is toggled off.
      {assertions = collisionAssertions;}
      # L2b → L3 fanout for per-CLI Dir options. Expansion happens
      # unconditionally (no mkIf cfg.enable) so the collision check
      # still has visibility even when the CLI is disabled — the
      # actual on-disk emission is still gated by `cfg.enable` inside
      # the per-CLI factory's customConfig.
      (lib.mkIf (cfg.rulesDir != null) {
        ai.${appRecord.name}.rules = lib.mapAttrs (_: lib.mkDefault) (
          dirHelpers.rulesFromDir cfg.rulesDir
        );
      })
      (lib.mkIf (cfg.skillsDir != null) {
        ai.${appRecord.name}.skills = lib.mapAttrs (_: lib.mkDefault) (
          dirHelpers.skillsFromDir cfg.skillsDir
        );
      })
      (lib.mkIf cfg.enable customConfig)
    ]
    ++ lib.optional hasOutputPath (lib.mkIf (cfg.enable && hasInstructions) {
      home.file.${outputPath}.text = renderedInstructions;
    })
  );
}
