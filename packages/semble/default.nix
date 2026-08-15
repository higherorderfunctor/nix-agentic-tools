# Per-package barrel for Semble's declarative integrations. The binary itself
# remains the unchanged llm-agents.nix flake output exposed by the overlay.
let
  customizePackage = import ./lib/withGrammars.nix;
in {
  docs = ./docs;

  lib.ai = {
    mcpServers.mkSemble = import ./lib/mkSemble.nix;
    semble =
      import ./lib/integrations.nix
      // {
        inherit customizePackage;
        withGrammars = args: package: grammars: (customizePackage args) package grammars [];
      };
  };

  modules = {
    devenv = ./modules/devenv;
    homeManager = ./modules/homeManager;
  };
}
