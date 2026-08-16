# Living-workflow home-manager module — the PRIMARY install path.
#
# Delegates to the shared skill-packaging factory (lib/ai/mkSkillPackageModule):
# `living-workflow.enable = true` installs the living-workflow skill USER-GLOBAL
# to ~/.claude/skills/ and ~/.kiro/skills/ via the PER-RUNTIME
# `ai.<runtime>.skills` pools (each enabled ecosystem fans it out) — NOT the
# consumer-owned root `ai.skills` pool, which would fan the package out beyond
# its runtime ownership. Those pools are per-`evalModules`, so this HM
# contribution is independent of the devenv module's project-local parity
# mirror.
#
# The skill is Nix-GENERATED: `lib/mkSkill.nix` bakes the XDG state base
# (`config.xdg.stateHome`) into SKILL.md's @XDG_STATE_BASE@ token and returns the
# generated skill's store-path STRING (see mkSkill.nix for why a string, not the
# derivation). No router: nothing this skill does is reachable by a stray
# hand-run command, so there is no rule that has to hold before the model
# considers the skill — and its description covers the rest. (Contrast
# stacked-workflows, whose skills wrap git commands a model can equally well run
# directly, so it pays for an always-loaded "check for a skill first" rule.)
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
