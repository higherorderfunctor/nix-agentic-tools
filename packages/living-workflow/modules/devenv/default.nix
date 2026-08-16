# Living-workflow devenv module — project-local PARITY mirror.
#
# Delegates to the shared skill-packaging factory (lib/ai/mkSkillPackageModule):
# `living-workflow.enable = true` re-contributes the same living-workflow skill
# at project-local (devenv) scope for consumers who want it per repo
# (config-parity rule). It lands on the PER-RUNTIME `ai.<runtime>.skills` pools
# rather than the root one. The package entry is a whole-entry default, so a
# consumer can replace it or suppress it with null in any runtime. Those pools
# are per-`evalModules`, so the HM module's contribution is invisible to devenv
# and vice-versa; each backend imports its own factory instance.
#
# State-base source: devenv eval has NO `config.xdg.stateHome` (that is a
# home-manager option). HM is the path that bakes the Nix-resolved absolute base
# (design D1); here, for parity, the skill bakes the standard XDG shell-default
# expression, which the agent's shell resolves at runtime.
#
# Picked up by `collectFacet ["modules" "devenv"]` in flake.nix.
import ../../../../lib/ai/mkSkillPackageModule.nix {
  name = "living-workflow";
  enableDescription = "the living-workflow skill (project-local devenv parity)";
  skills = {pkgs, ...}: {
    living-workflow = import ../../lib/mkSkill.nix {inherit pkgs;} {
      stateBase = "\${XDG_STATE_HOME:-$HOME/.local/state}/living-workflows";
      src = ../../skills/living-workflow;
    };
  };
}
