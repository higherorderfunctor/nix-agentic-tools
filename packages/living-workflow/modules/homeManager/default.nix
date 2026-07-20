# Living-workflow home-manager module — the PRIMARY install path.
#
# Delegates to the shared skill-packaging factory (lib/ai/mkSkillPackageModule):
# `living-workflow.enable = true` installs the living-workflow skill USER-GLOBAL
# to ~/.claude/skills/ and ~/.kiro/skills/ via the cross-ecosystem `ai.skills`
# pool (each enabled ecosystem fans it out). The `ai.skills` pool is
# per-`evalModules`, so this HM contribution is independent of the devenv
# module's project-local parity mirror.
#
# The skill is Nix-GENERATED: `lib/mkSkill.nix` bakes the XDG state base
# (`config.xdg.stateHome`) into SKILL.md's @XDG_STATE_BASE@ token and returns the
# generated skill's store-path STRING (see mkSkill.nix for why a string, not the
# derivation). Single skill, no sibling disambiguation → no router (unlike
# stacked-workflows, which ships several sibling skills + a routing table).
#
# Picked up by `collectFacet ["modules" "homeManager"]` in flake.nix.
import ../../../../lib/ai/mkSkillPackageModule.nix {
  name = "living-workflow";
  enableDescription = "the living-workflow skill (user-global: ~/.claude/skills/ + ~/.kiro/skills/)";
  skills = {
    config,
    pkgs,
    ...
  }: {
    living-workflow = import ../../lib/mkSkill.nix {inherit pkgs;} {
      stateBase = "${config.xdg.stateHome}/living-workflows";
      src = ../../skills/living-workflow;
    };
  };
}
