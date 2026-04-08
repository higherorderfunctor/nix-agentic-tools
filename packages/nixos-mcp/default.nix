{
  docs = ./docs;
  fragments = ./fragments;
  lib.ai.mcpServers.mkNixos = import ./lib/mkNixos.nix;
}
