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
# Milestone 1 scope: option tree + fanout merge only. The
# `transformers` arg is captured for Milestone 2 (real markdown
# rendering via `transformers.markdown` + `outputPath` → home.file).
# It's exposed via `_module.args.aiTransformers` so the inner module
# can reach it once the rendering wiring lands.
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
      # Always thread the transformers record into module args so
      # downstream rendering wiring (Milestone 2) can read it without
      # the factory needing a second binding cycle.
      {_module.args.aiTransformers = transformers;}
      # Milestone 1: option tree + fanout merge only.
      # The custom config callback fires only when the app is enabled.
      # Real markdown/instructions rendering lands in Milestone 2.
      (lib.mkIf cfg.enable customConfig)
    ];
  }
