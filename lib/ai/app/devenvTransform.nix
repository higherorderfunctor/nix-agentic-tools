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
  cfg = config.ai.${appRecord.name};
  mergedServers = config.ai.mcpServers // cfg.mcpServers;
  mergedInstructions = config.ai.instructions ++ cfg.instructions;
  mergedSkills = config.ai.skills // cfg.skills;

  devenvSpec = appRecord.devenv or {};
  devenvOptions = devenvSpec.options or {};
  devenvDefaults = devenvSpec.defaults or {};
  devenvConfigFn = devenvSpec.config or (_: {});

  defaults = appRecord.defaults or {};
  package = devenvDefaults.package or defaults.package or null;
  outputPath = devenvDefaults.outputPath or defaults.outputPath or null;

  customConfig = devenvConfigFn {
    inherit cfg mergedServers mergedInstructions mergedSkills;
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
      (lib.mkIf cfg.enable customConfig)
    ]
    ++ lib.optional hasOutputPath (lib.mkIf (cfg.enable && hasInstructions) {
      files.${outputPath}.text = renderedInstructions;
    })
  );
}
