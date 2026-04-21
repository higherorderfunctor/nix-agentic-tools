# Stacked-workflows home-manager module.
#
# HM scope is git-config only. Skills, instructions, and reference
# docs moved to the devenv module (project-local scope) because
# sws-prefixed skills leaking into `~/.claude/skills/` collided with
# the user's personal-scope `stack-*` skills.
#
# See `docs/stacked-workflows-scope-fix-plan.md` for the scope-fix
# root cause: shared-option pools (`ai.skills`, `ai.instructions`)
# are per-`evalModules`, NOT cross-backend. A value set in the HM
# module is only visible to HM's eval; devenv has a separate eval.
# Placing contributions in the HM module meant they landed in
# personal HM scope and were missing from devenv entirely.
#
# Picked up by `collectFacet ["modules" "homeManager"]` in flake.nix.
{
  config,
  lib,
  ...
}: let
  cfg = config.stacked-workflows;

  # Apply mkDefault to every leaf value in a nested attrset so users can
  # override individual keys at normal priority.
  mkDefaultRecursive = lib.mapAttrsRecursive (_path: lib.mkDefault);

  gitConfigMinimal = import ./git-config.nix;
  gitConfigFull = import ./git-config-full.nix;

  gitSettings = {
    "full" = gitConfigFull;
    "minimal" = gitConfigMinimal;
    "none" = {};
  };
in {
  options.stacked-workflows = {
    enable = lib.mkEnableOption "stacked workflow git config presets (skills/instructions/refs live in the devenv module — project-local scope)";

    gitPreset = lib.mkOption {
      type = lib.types.enum ["full" "minimal" "none"];
      default = "none";
      description = ''
        Git configuration preset for stacked workflows.

        - `"minimal"` -- required + strongly recommended settings
        - `"full"` -- all recommended settings (branchless, revise, general git)
        - `"none"` -- no git configuration changes

        All values are set at `mkDefault` priority so you can override
        individual keys at normal priority in `programs.git.settings`.
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    # ── Assertions ─────────────────────────────────────────────────────
    {
      assertions = [
        {
          assertion =
            !(cfg.gitPreset
              != "none"
              && (lib.attrByPath ["pull" "ff"] null
                config.programs.git.settings)
              != null);
          message = ''
            programs.git.settings.pull.ff conflicts with
            stacked-workflows.gitPreset.

            Since Git 2.34, pull.ff = "only" takes priority over
            pull.rebase = true, causing "git pull" to fail when local
            commits exist. Remove pull.ff from your git settings or set
            stacked-workflows.gitPreset = "none".
          '';
        }
      ];
    }

    # ── Git configuration ──────────────────────────────────────────────
    (lib.mkIf (cfg.gitPreset != "none") {
      programs.git.settings = mkDefaultRecursive gitSettings.${cfg.gitPreset};
    })
  ]);
}
