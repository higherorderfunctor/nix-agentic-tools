# Generic factory for AI-app module functions.
#
# Factory-of-factory pattern: outer call supplies package-specific
# defaults + custom options + custom config callback. Returns a module
# function the HM/devenv module system can import.
#
# The inner module reads from sharedOptions
# (ai.mcpServers, ai.instructions, ai.skills) AND from its own per-app
# options (ai.<name>.mcpServers, etc.), merges them with per-app
# winning on conflict, and threads the merged view into both the
# baseline rendering and the factory's custom config callback.
#
# Baseline rendering pipeline:
# When `defaults.outputPath` is set AND at least one instruction
# fragment is merged, each fragment is passed through
# `transformers.markdown.render` and the concatenated result is
# written to `home.file.${defaults.outputPath}.text`. Consumers
# enabling `ai.<name>.enable = true` and providing
# `ai.instructions = [frag1 frag2 ...]` (or per-app
# `ai.<name>.instructions`) get a real rule file at the output path.
#
# Custom config callbacks receive `{cfg, mergedServers,
# mergedInstructions, mergedSkills}` and can do anything on top of
# the baseline render — e.g., write per-scope rule files, generate
# MCP server config, run activation scripts.
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

    # Baseline render: walk mergedInstructions through
    # transformers.markdown.render and join with double-newline.
    # Each instruction fragment is an attrset like
    # `{ text, description ? null, paths ? null, ... }`; the
    # transformer reads those attrs to produce frontmatter + body.
    renderedInstructions =
      lib.concatMapStringsSep "\n\n" (
        frag: transformers.markdown.render frag
      )
      mergedInstructions;

    # Only emit home.file when the app declares an outputPath AND
    # at least one instruction fragment was merged. Apps without an
    # outputPath (daemon-only, binary-only) or with empty
    # instructions produce no file output from the baseline. These
    # let-bindings are consumed by the mkMerge list below to gate
    # the optional baseline home.file element.
    hasOutputPath = (defaults.outputPath or null) != null;
    hasInstructions = mergedInstructions != [];
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

    config = lib.mkMerge (
      [
        # Thread the transformers record into module args so consumers
        # composing their own downstream modules can reach it.
        {_module.args.aiTransformers = transformers;}
        # Per-app custom config callback — fires only when enabled.
        (lib.mkIf cfg.enable customConfig)
      ]
      # Baseline instruction rendering — ONLY included when the app
      # has an outputPath declared (so binary-only factories don't
      # drag home.file into contexts that don't have it). The
      # `lib.mkIf cfg.enable` gates the actual write, so the home.file
      # path stays inert until the app is enabled. Both hasOutputPath
      # and hasInstructions are eval-time constants from the outer
      # let-block, so this conditional is resolved BEFORE the module
      # system type-checks option paths.
      ++ lib.optional hasOutputPath (lib.mkIf (cfg.enable && hasInstructions) {
        home.file.${defaults.outputPath}.text = renderedInstructions;
      })
    );
  }
