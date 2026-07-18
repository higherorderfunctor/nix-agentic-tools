# Stacked-workflows devenv module — project-local scope.
#
# Mirrors the HM module's skill + routing-table fanout at project (devenv)
# scope via the cross-ecosystem `ai.*` pools. `ai.skills` is per-`evalModules`,
# so this contribution is independent of the HM one. Reference docs travel
# inside each skill dir (real files from the content build), so there is no
# separate `.claude/references/` write.
#
# The `enable` option is declared here independently of the HM module's
# `enable` because HM and devenv run separate evalModules invocations. When
# the same repo loads both, consumers can enable independently or in tandem.
#
# Picked up by `collectFacet ["modules" "devenv"]` in flake.nix.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.stacked-workflows;
  skills = pkgs.stacked-workflows-content.passthru.skills;
  router = import ../../router.nix {inherit lib pkgs;};
in {
  options.stacked-workflows = {
    enable = lib.mkEnableOption "stacked workflow skills + routing table (project-local devenv scope)";
  };

  config = lib.mkIf cfg.enable {
    ai.skills = lib.mapAttrs (_: lib.mkDefault) skills;
    ai.instructions = router;
  };
}
