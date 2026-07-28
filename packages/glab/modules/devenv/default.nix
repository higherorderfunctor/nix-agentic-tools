# glab devenv module — project-local scope.
#
# Option DECLARATIONS live in ../options.nix, shared with the
# home-manager facet so the two cannot drift. This file is only the
# devenv-side wiring: default the package out of the overlay and put the
# wrapped glab in the project's dev shell.
#
# The wrapper reads its secrets at invocation time, so a project-local
# glab picks up a rotated sops file with no shell re-entry — the same
# behavior the HM facet gets.
#
# Picked up by `collectFacet ["modules" "devenv"]` in flake.nix.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.glab;
in {
  imports = [(import ../options.nix {inherit lib;})];

  config = lib.mkIf cfg.enable {
    glab.package = lib.mkDefault pkgs.generic.glab;

    packages = [
      (import ../../lib/mkGlab.nix {inherit lib pkgs cfg;})
    ];
  };
}
