{
  docs = ./docs;
  fragments = ./fragments;
  lib.ai.mcpServers.mkProxy = import ./lib/mkProxy.nix;
}
