# Stacked workflows devshell module — injects skills and references
# into the devshell project directory.
#
# Content populated in Phase 3.1 when skills migrate.
{
  config,
  lib,
  ...
}: let
  cfg = config.skills.stacked-workflows;
in {
  options.skills.stacked-workflows = {
    enable = lib.mkEnableOption "stacked workflow skills in the devshell";

    gitPreset = lib.mkOption {
      type = lib.types.enum ["full" "minimal" "none"];
      default = "none";
      description = "Git configuration preset for stacked workflows.";
    };
  };

  config = lib.mkIf cfg.enable {
    packages = [
      # Added when overlays migrate in Phase 3.2:
      # pkgs.git-absorb
      # pkgs.git-branchless
      # pkgs.git-revise
    ];

    # Skill files and references will be materialized via config.files
    # once packages/stacked-workflows content is wired to this module.
  };
}
