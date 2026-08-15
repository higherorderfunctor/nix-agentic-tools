# Stacked-workflows devenv module — project-local scope.
#
# Delegates to the shared skill-packaging factory (lib/ai/mkSkillPackageModule):
# `stacked-workflows.enable = true` fans the unprefixed stack-* skills and the
# skill-routing rule into the PER-RUNTIME
# `ai.<runtime>.{skills,rules}` pools at project-local (devenv) scope —
# NOT the root pools, which are additive and cannot be retracted per runtime.
# Those pools are per-`evalModules`, so this contribution is independent of the
# HM module's.
#
# Skills come from `pkgs.stacked-workflows-content.passthru.skills` — the
# deref'd, self-contained skill dirs (real reference files bundled inside each,
# so they resolve in every scope). Values are store-path strings, accepted by
# the skills fanout helpers.
#
# Picked up by `collectFacet ["modules" "devenv"]` in flake.nix.
import ../../../../lib/ai/mkSkillPackageModule.nix {
  name = "stacked-workflows";
  enableDescription = "stacked workflow skills + skill-routing rule (project-local devenv scope)";
  skills = {pkgs, ...}: pkgs.stacked-workflows-content.passthru.skills;
  rules = {
    lib,
    pkgs,
    ...
  }:
    import ../../router.nix {inherit lib pkgs;};
}
