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
  cfg = config.ai.${appRecord.name};
  mergedServers = config.ai.mcpServers // cfg.mcpServers;
  mergedInstructions = config.ai.instructions ++ cfg.instructions;
  mergedSkills = config.ai.skills // cfg.skills;

  hmSpec = appRecord.hm or {};
  hmOptions = hmSpec.options or {};
  hmDefaults = hmSpec.defaults or {};
  hmConfigFn = hmSpec.config or (_: {});

  defaults = appRecord.defaults or {};
  package = hmDefaults.package or defaults.package or null;
  outputPath = hmDefaults.outputPath or defaults.outputPath or null;

  customConfig = hmConfigFn {
    inherit cfg mergedServers mergedInstructions mergedSkills;
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
      skills = lib.mkOption {
        type = lib.types.attrsOf lib.types.path;
        default = {};
        description = "${appRecord.name}-specific skills (merged with top-level ai.skills; per-app wins).";
      };
    }
    // (appRecord.options or {})
    // hmOptions;

  config = lib.mkMerge (
    [
      {_module.args.aiTransformers = appRecord.transformers;}
      (lib.mkIf cfg.enable customConfig)
    ]
    ++ lib.optional hasOutputPath (lib.mkIf (cfg.enable && hasInstructions) {
      home.file.${outputPath}.text = renderedInstructions;
    })
  );
}
