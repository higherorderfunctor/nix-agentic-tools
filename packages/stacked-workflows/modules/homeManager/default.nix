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
# On TOP of the factory, both backends import `stacked-workflows.gitPreset`
# (../options.nix) outside `ai.*`: it is sugar over the `git.*` options, which
# Home Manager delivers through `programs.git.settings`. It has no runtime
# meaning. Skill sources are the deref'd, self-contained skill dirs from
# `pkgs.stacked-workflows-content.passthru.skills` (real reference files
# bundled inside each, so they resolve in every scope).
#
# Picked up by `native Home Manager module discovery` in flake.nix.
{lib, ...}: {
  imports = [
    (import ../../../../lib/ai/mkSkillPackageModule.nix {
      name = "stacked-workflows";
      enableDescription = "stacked workflow skills and skill-routing rule in each enabled runtime";
      skills = {pkgs, ...}: pkgs.stacked-workflows-content.passthru.skills;
      rules = {
        lib,
        pkgs,
        ...
      }:
        import ../../router.nix {inherit lib pkgs;};
    })
    (import ../options.nix {inherit lib;})
  ];
}
