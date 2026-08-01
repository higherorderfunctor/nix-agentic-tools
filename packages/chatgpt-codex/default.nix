# Per-package barrel for chatgpt-codex.
#
# The binary derivation lives in overlays/chatgpt-codex.nix. This barrel
# exposes the configuration factory and its Home Manager/devenv projections.
{
  lib.ai.apps.mkCodex = import ./lib/mkCodex.nix;

  modules = {
    devenv = ./modules/devenv;
    homeManager = ./modules/homeManager;
  };
}
