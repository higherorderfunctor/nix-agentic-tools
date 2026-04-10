# Per-package barrel for stacked-workflows.
#
# The content derivation (pkgs.stacked-workflows-content) lives in
# overlay.nix (imported by flake.nix as a separate overlay).
# This file exposes the non-binary facets: modules.
{
  modules = {
    devenv = ./modules/devenv;
    homeManager = ./modules/homeManager;
  };
}
