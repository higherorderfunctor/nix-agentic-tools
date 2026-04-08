# Factory-of-factory for nixos-mcp.
#
# Consumers call `lib.ai.mcpServers.mkNixos {...}` from their config
# to produce a typed attrset that conforms to the common MCP server
# schema (type, package, command, args, env, settings, url).
#
# This server is sourced from inputs.mcp-nixos (not nvfetcher-tracked).
{
  lib,
  pkgs,
  ...
}:
lib.ai.mcpServer.mkMcpServer {
  name = "nixos";
  defaults = {
    package = pkgs.ai.nixos-mcp;
    type = "stdio";
    command = "mcp-nixos";
    args = [];
  };
  # No custom options — nixos-mcp has no unique config knobs
  # beyond the common schema.
}
