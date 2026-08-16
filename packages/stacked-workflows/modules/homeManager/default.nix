# Stacked-workflows home-manager module — user-global install.
#
# The skills + skill-routing fanout is delegated to the shared skill-packaging
# factory (lib/ai/mkSkillPackageModule), imported below:
# `ai.programs.stacked-workflows.enable = true` fans the unprefixed stack-*
# skills and the skill-routing rule
# into the PER-RUNTIME `ai.<runtime>.{skills,rules}` pools of every
# runtime present in the evaluation, so each enabled ecosystem installs them
# user-global (~/.claude/skills, ~/.kiro/skills, ~/.claude/CLAUDE.md,
# ~/.kiro/steering/, ...). NOT the root `ai.skills` pool — a root write is
# consumer-owned and would fan out beyond package runtime ownership; see the
# factory's header. Those pools are per-`evalModules`, so this HM-scope
# contribution is independent of the devenv module's.
#
# On TOP of the factory, this module keeps the HM-only
# `stacked-workflows.gitPreset` companion option outside `ai.*`: Git presets
# configure the machine-wide Home Manager `programs.git.settings` surface and
# have no runtime-specific or devenv analogue. Keeping that boundary explicit
# avoids generating meaningless `ai.<runtime>.programs.stacked-workflows`
# `gitPreset` overrides. Skill sources are the deref'd, self-contained skill
# dirs from `pkgs.stacked-workflows-content.passthru.skills` (real reference
# files bundled inside each, so they resolve in every scope).
#
# Picked up by `collectFacet ["modules" "homeManager"]` in flake.nix.
{
  config,
  lib,
  ...
}: let
  cfg = config.ai.programs.stacked-workflows;
  gitPreset = config.stacked-workflows.gitPreset;

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
  imports = [
    (import ../../../../lib/ai/mkSkillPackageModule.nix {
      name = "stacked-workflows";
      enableDescription = "stacked workflow skills, skill-routing rule, and git-config presets (user-global)";
      skills = {pkgs, ...}: pkgs.stacked-workflows-content.passthru.skills;
      rules = {
        lib,
        pkgs,
        ...
      }:
        import ../../router.nix {inherit lib pkgs;};
    })
  ];

  options.stacked-workflows = {
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
            !(gitPreset
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
    (lib.mkIf (gitPreset != "none") {
      programs.git.settings = mkDefaultRecursive gitSettings.${gitPreset};
    })
  ]);
}
