# stacked-workflows home-manager module.
# Provides git tool overlays, git config presets, and per-ecosystem
# skill/instruction injection.
# Implementation in Phase 3.5.
{lib, ...}: {
  options.stacked-workflows = {
    enable = lib.mkEnableOption "stacked workflow skills and git tools";
    gitPreset = lib.mkOption {
      type = lib.types.enum ["full" "minimal" "none"];
      default = "none";
      description = "Git configuration preset for stacked workflows.";
    };
  };
}
