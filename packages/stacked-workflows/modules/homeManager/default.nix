# Stacked-workflows home-manager module — user-global install.
#
# `stacked-workflows.enable = true` fans the stack skills and the
# routing-table instruction into the cross-ecosystem `ai.*` pools, so each
# enabled ecosystem installs them user-global (~/.claude/skills,
# ~/.kiro/skills, ~/.claude/CLAUDE.md, ~/.kiro/steering/, ...). Also applies
# optional git-config presets.
#
# Skill sources are the deref'd, self-contained skill dirs from
# `pkgs.stacked-workflows-content.passthru.skills` — real reference files are
# bundled inside each skill dir, so they resolve in every scope. The values
# are store-path strings, accepted by the modern upstream `isPathLike`
# skill-entry check (see lib/ai path-type notes).
#
# `ai.skills` is per-`evalModules`, so this HM-scope contribution is
# independent of the devenv module's project-scope contribution.
#
# Picked up by `collectFacet ["modules" "homeManager"]` in flake.nix.
{
  config,
  lib,
  pkgs,
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

  skills = pkgs.stacked-workflows-content.passthru.skills;
  router = import ../../router.nix {inherit lib pkgs;};
in {
  options.stacked-workflows = {
    enable = lib.mkEnableOption "stacked workflow skills, routing table, and git-config presets (user-global)";

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

    # ── Skills + routing table (user-global via ai.* pools) ────────────
    {
      ai.skills = lib.mapAttrs (_: lib.mkDefault) skills;
      ai.instructions = router;
    }

    # ── Git configuration ──────────────────────────────────────────────
    (lib.mkIf (cfg.gitPreset != "none") {
      programs.git.settings = mkDefaultRecursive gitSettings.${cfg.gitPreset};
    })
  ]);
}
