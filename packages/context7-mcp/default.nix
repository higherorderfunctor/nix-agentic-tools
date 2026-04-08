# Per-package barrel for context7-mcp.
#
# MCP servers don't contribute HM/devenv modules — they contribute a
# factory-of-factory to lib.ai.mcpServers.mkContext7 that consumers
# invoke at config time to produce typed attrset entries for the
# shared ai.mcpServers pool or per-app ai.<name>.mcpServers overrides.
{
  fragments = ./fragments;
  docs = ./docs;
  lib.ai.mcpServers.mkContext7 = import ./lib/mkContext7.nix;
}
