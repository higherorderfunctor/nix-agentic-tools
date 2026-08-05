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
  options,
  pkgs,
  ...
}: let
  cfg = config.glab;
in {
  imports = [(import ../options.nix {inherit lib;})];

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      glab.package = lib.mkDefault pkgs.ai.devTools.glab;

      home.packages = [
        (import ../../lib/mkGlab.nix {inherit lib pkgs cfg;})
      ];
    }
    (lib.mkIf (lib.hasAttrByPath ["ai" "codex" "settings"] options && config.ai.codex.enable) {
      ai.codex.settings._integration_writable_roots = lib.mkAfter [
        (
          if cfg.configDir != null
          then cfg.configDir
          else "${config.xdg.configHome}/glab-cli"
        )
      ];
    })
  ]);
}
