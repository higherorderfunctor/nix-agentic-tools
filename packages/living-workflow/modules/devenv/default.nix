# Living-workflow devenv module — project-local PARITY mirror.
#
# The `ai.skills` pool is per-`evalModules`, so the home-manager module's
# contribution is invisible to devenv and vice-versa. This module
# re-contributes the same living-workflow skill at project-local (devenv)
# scope for consumers who want it per repo (config-parity rule).
#
# Each backend module declares its OWN `enable` option — HM and devenv are
# separate eval trees, each needs its own option node.
#
# State-base source: devenv eval has NO `config.xdg.stateHome` (that is a
# home-manager option). HM is the path that bakes the Nix-resolved absolute
# base (design D1); here, for parity, the skill bakes the standard XDG
# shell-default expression, which the agent's shell resolves at runtime.
#
# Picked up by `collectFacet ["modules" "devenv"]` in flake.nix.
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
    enable = lib.mkEnableOption "the living-workflow skill (project-local devenv parity)";
  };

  config = lib.mkIf cfg.enable {
    ai.skills.living-workflow = mkSkill {
      stateBase = "\${XDG_STATE_HOME:-$HOME/.local/state}/living-workflows";
      src = ../../skills/living-workflow;
    };
  };
}
