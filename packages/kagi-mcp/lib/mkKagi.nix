# Factory-of-factory for kagi-mcp.
#
# Consumers call `lib.ai.mcpServers.mkKagi {...}` from their config
# to produce a typed attrset that conforms to the common MCP server
# schema (type, package, command, args, env, settings, url).
#
# TODO(milestone-N): add a `apiKey` option for Kagi API authentication.
# The KAGI_API_KEY env var will need a typed option surface once consumer
# needs materialize.
{
  lib,
  pkgs,
  ...
}:
lib.ai.mcpServer.mkMcpServer {
  name = "kagi";
  defaults = {
    package = pkgs.ai.kagi-mcp;
    type = "stdio";
    command = "kagimcp";
    args = [];
  };
  # No custom options in this milestone — auth options deferred.
  options = {};
}
