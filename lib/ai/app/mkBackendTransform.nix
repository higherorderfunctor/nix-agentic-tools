# Shared backend transformer body.
#
# `hmTransform.nix` and `devenvTransform.nix` were ~135 near-identical
# lines each. Every merge, every option declaration and the whole
# `config` block were duplicated verbatim; the ONLY functional
# difference was which key of the app record the backend-specific
# spec is read from (`hm` vs `devenv`). That is this file's `backend`
# argument, and nothing else differs.
#
# Keeping them as two copies meant every change to the shared option
# surface had to be made twice, and the two had already drifted — the
# devenv copy's `mcpServers`, `instructions`, `skills` and `skillsDir`
# descriptions had lost the merge semantics the HM copy documented,
# even though both run the SAME merge code. Unifying on the fuller
# text makes the devenv option docs correct rather than terse.
#
# Input record shape (from mkAiApp):
#   {
#     name;
#     transformers;
#     defaults ? {package};
#     options ? {};            # shared across backends
#     <backend> ? {
#       options ? {};          # backend-only option additions
#       defaults ? {};         # backend-only default overrides
#       config ? _: {};        # consumer callback:
#                              #   {cfg, config, merged*, topContext} → module attrs
#     };
#     <other-backend> ? { ... };   # ignored here
#   }
#
# Returns: a module function `{config, ...}: { options; config; }`
# that can be imported into `lib.evalModules` alongside
# `lib/ai/sharedOptions.nix`.
{
  lib,
  # Which key of the app record carries this backend's spec.
  backend,
}: appRecord: {config, ...}: let
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

  backendSpec = appRecord.${backend} or {};
  backendOptions = backendSpec.options or {};
  backendDefaults = backendSpec.defaults or {};
  backendConfigFn = backendSpec.config or (_: {});

  defaults = appRecord.defaults or {};
  package = backendDefaults.package or defaults.package or null;

  # `config` rides along so callbacks can observe sibling backend
  # options — e.g. the devenv materializer's conditional `devenv:files`
  # task edge needs `config.files != {}`.
  customConfig = backendConfigFn {
    inherit cfg config mergedServers mergedInstructions mergedSkills mergedRules mergedLspServers mergedEnvironmentVariables mergedClaudeCopilotAgents topContext;
  };
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
        description = "${appRecord.name}-specific MCP servers (merged with top-level ai.mcpServers; collisions fail).";
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
    // backendOptions;

  config = lib.mkMerge [
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
  ];
}
