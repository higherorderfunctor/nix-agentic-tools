# Instructions devshell module — generates ecosystem instruction files
# from fragments for the current project.
#
# Uses the same fragment pipeline as the monorepo but scoped to
# what the consumer project needs.
{lib, ...}: let
  aiTypes = import ../../lib/ai/types.nix {inherit lib;};
in {
  options.instructions = {
    enable = lib.mkEnableOption "instruction file generation in the devshell";

    projectDescription = lib.mkOption {
      type = aiTypes.optionalTextSource {
        description = "the custom project description included in generated instructions";
        enableDefault = false;
      };
      default = {};
      description = ''
        Custom project description to include in generated instructions.
        When disabled, only standard fragments are included.
      '';
    };
  };

  # Implementation deferred to Phase 3 when fragment pipeline is fully
  # integrated. The pattern will be:
  #
  # config = lib.mkIf cfg.enable {
  #   files.".claude/rules/nix-agentic-tools.md".text = ...;
  #   files.".kiro/steering/nix-agentic-tools.md".text = ...;
  #   files.".github/instructions/nix-agentic-tools.instructions.md".text = ...;
  # };
}
