# Living-workflow home-manager module — the PRIMARY install path.
#
# Scope is USER-GLOBAL: `living-workflow.enable = true` installs the
# living-workflow skill to ~/.claude/skills/ and ~/.kiro/skills/ via the
# cross-ecosystem `ai.skills` pool (each enabled ecosystem fans it out).
#
# This INVERTS stacked-workflows' scope choice (which keeps skills
# project-local in its devenv module) on purpose: the living-workflow
# machinery should follow the operator across surfaces without loading a
# devenv module per repo. The devenv module is a project-local parity
# mirror — the `ai.skills` pool is per-`evalModules`, so a value set here
# is visible only to HM's eval; devenv has its own separate contribution.
#
# The skill is Nix-GENERATED: it bakes the XDG state base
# (`config.xdg.stateHome`, the design's baked-absolute-path pattern) into
# SKILL.md's @XDG_STATE_BASE@ token. `ai.skills` receives the generated
# skill's store-path STRING (see lib/mkSkill.nix for why a string, not the
# derivation).
#
# Picked up by `collectFacet ["modules" "homeManager"]` in flake.nix.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.living-workflow;
  mkSkill = import ../../lib/mkSkill.nix {inherit pkgs;};
in {
  options.living-workflow = {
    enable = lib.mkEnableOption "the living-workflow skill (user-global: ~/.claude/skills/ + ~/.kiro/skills/)";
  };

  config = lib.mkIf cfg.enable {
    ai.skills.living-workflow = mkSkill {
      stateBase = "${config.xdg.stateHome}/living-workflows";
      src = ../../skills/living-workflow;
    };
  };
}
