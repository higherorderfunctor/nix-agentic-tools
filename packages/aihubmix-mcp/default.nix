# Per-package barrel for aihubmix-mcp.
#
# MCP servers don't contribute HM/devenv modules — they contribute a
# factory-of-factory to lib.ai.mcpServers.mkAihubmix that consumers
# invoke at config time to produce typed attrset entries for the
# shared ai.mcpServers pool or per-app ai.<name>.mcpServers overrides.
#
# No modules/mcp-server.nix here: that file drives the
# `services.mcp-servers` systemd surface, which only covers servers this
# repo runs as long-lived HTTP/stdio services. aihubmix-mcp is a plain
# stdio server launched by the client, like mcp-proxy and
# mcp-language-server, which are also barrel-only.
{
  fragments = ./fragments;
  docs = ./docs;
  lib.ai.mcpServers.mkAihubmix = import ./lib/mkAihubmix.nix;
}
