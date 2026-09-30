# Stacked-workflows devenv module — project-local scope.
#
# Delegates to the shared skill-packaging factory (lib/ai/mkSkillPackageModule):
# `ai.programs.stacked-workflows.enable = true` fans the unprefixed stack-*
# skills and the skill-routing rule into the PER-RUNTIME
# `ai.<runtime>.{skills,rules}` pools at project-local (devenv) scope —
# NOT the consumer-owned root pools, which would fan the package out beyond its
# runtime ownership. Those pools are per-`evalModules`, so this contribution is
# independent of the HM module's.
#
# Skills come from `pkgs.stacked-workflows-content.passthru.skills` — the
# deref'd, self-contained skill dirs (real reference files bundled inside each,
# so they resolve in every scope). Values are store-path strings, accepted by
# the skills fanout helpers.
#
# `stacked-workflows.gitPreset` (../options.nix, shared with Home Manager) is
# sugar over the `git.*` options; packages/git delivers them as a
# repository-local include and packages/git-branchless runs
# `git branchless init`.
#
# Picked up by `native devenv module discovery` in flake.nix.
{lib, ...}: {
  imports = [
    (import ../../../../lib/ai/mkSkillPackageModule.nix {
      name = "stacked-workflows";
      enableDescription = "stacked workflow skills + skill-routing rule (project-local devenv scope)";
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
