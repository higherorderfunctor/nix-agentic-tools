# glab home-manager module — user-global install.
#
# Option DECLARATIONS live in ../options.nix, shared with the devenv
# facet so the two cannot drift. This file is only the HM-side wiring:
# default the package out of the overlay and put the wrapped glab on the
# user's PATH.
#
# Picked up by `collectFacet ["modules" "homeManager"]` in flake.nix.
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

    home.packages = [
      (import ../../lib/mkGlab.nix {inherit lib pkgs cfg;})
    ];
  };
}
