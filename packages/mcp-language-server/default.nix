{
  docs = ./docs;
  fragments = ./fragments;
  lib.ai.mcpServers.mkLanguageServer = import ./lib/mkLanguageServer.nix;
}
