# Generic factory for AI-app module functions.
#
# Factory-of-factory pattern: outer call supplies package-specific
# defaults + custom options + custom config callback. Returns a module
# function the HM/devenv module system can import.
#
# The inner module reads from sharedOptions
# (ai.mcpServers, ai.instructions, ai.skills) AND from its own per-app
# options (ai.<name>.mcpServers, etc.), merges them with per-app
# winning on conflict, and threads the merged view into the factory's
# custom config callback.
#
# DEFERRED: the `transformers` arg and `defaults.outputPath` are
# captured into the option tree + `_module.args.aiTransformers` but
# no rendering pipeline currently writes merged instructions to
# home.file / files.*. Consumers enabling `ai.<name>.enable = true`
# get the option tree (including mcpServers fanout) but NO instruction
# file output until the rendering wiring lands in a follow-up. This
# is a known gap — the factory IS correct for option composition and
# MCP server fanout; it's just that the final "merge these fragments
# and write them to CLAUDE.md / copilot-instructions.md / etc." step
# is not yet done.
{lib}: {
  name,
  transformers,
  defaults,
  options ? {},
  config ? (_: {}),
}: let
  # Capture outer args under aliased names so they don't shadow the
  # inner module function's parameters (`config`, etc.).
  customOptions = options;
  customConfigFn = config;
in
  {config, ...}: let
    cfg = config.ai.${name};
    mergedServers = config.ai.mcpServers // cfg.mcpServers;
    mergedInstructions = config.ai.instructions ++ cfg.instructions;
    mergedSkills = config.ai.skills // cfg.skills;
    customConfig = customConfigFn {
      inherit cfg mergedServers mergedInstructions mergedSkills;
    };
  in {
    options.ai.${name} =
      {
        enable = lib.mkEnableOption name;
        package = lib.mkOption {
          type = lib.types.package;
          default = defaults.package;
          description = "The ${name} package.";
        };
        mcpServers = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submoduleWith {
            modules = [(import ../mcpServer/commonSchema.nix)];
          });
          default = {};
          description = "${name}-specific MCP servers (merged with top-level ai.mcpServers; per-app wins on conflict).";
        };
        instructions = lib.mkOption {
          type = lib.types.listOf lib.types.attrs;
          default = [];
          description = "${name}-specific instructions (appended to top-level ai.instructions).";
        };
        skills = lib.mkOption {
          type = lib.types.attrsOf lib.types.path;
          default = {};
          description = "${name}-specific skills (merged with top-level ai.skills; per-app wins).";
        };
      }
      // customOptions;

    config = lib.mkMerge [
      # Thread the transformers record into module args so a future
      # rendering wiring can read it without the factory needing a
      # second binding cycle.
      {_module.args.aiTransformers = transformers;}
      # Option tree + fanout merge only — the custom config callback
      # fires only when the app is enabled. Instruction file rendering
      # (transformers.markdown over mergedInstructions → home.file at
      # defaults.outputPath) is not yet wired; see the DEFERRED note
      # at the top of this file.
      (lib.mkIf cfg.enable customConfig)
    ];
  }
