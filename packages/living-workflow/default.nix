# Per-package barrel for living-workflow.
#
# The living-workflow skill is a Nix-GENERATED router: it bakes the XDG
# state base (config.xdg.stateHome) into its SKILL.md at eval time, then
# contributes itself to the cross-ecosystem `ai.skills` pool.
#
# Install scope (design D1): the home-manager module is the PRIMARY path —
# `living-workflow.enable = true` installs the skill USER-GLOBAL to
# ~/.claude/skills/ and ~/.kiro/skills/. The devenv module is a
# project-local PARITY mirror (the `ai.skills` pool is per-`evalModules`,
# so HM and devenv are wired independently — config-parity rule).
#
# No overlay / `-content` derivation: because the skill bakes a per-eval
# value (config.xdg.stateHome), a static overlay-time derivation (built
# once, independent of any consumer's config) would be the wrong place to
# bake it. The generation lives in the modules.
#
# The modules are picked up by `collectFacet ["modules" ...]` in flake.nix
# (walks packages/default.nix) — no manual flake.nix edit is needed.
{
  modules = {
    devenv = ./modules/devenv;
    homeManager = ./modules/homeManager;
  };
}
