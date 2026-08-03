# Per-package barrel for Semble's declarative integrations. The binary itself
# remains the unchanged llm-agents.nix flake output exposed by the overlay.
{
  docs = ./docs;

  lib.ai = {
    mcpServers.mkSemble = import ./lib/mkSemble.nix;
    semble = import ./lib/integrations.nix;
  };

  modules = {
    devenv = ./modules/devenv;
    homeManager = ./modules/homeManager;
  };
}
