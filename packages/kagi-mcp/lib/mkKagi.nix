# Factory-of-factory for kagi-mcp.
#
# Consumers call `lib.ai.mcpServers.mkKagi {...}` from their config
# to produce a typed attrset that conforms to the common MCP server
# schema (type, package, command, args, env, settings, url).
#
# Typed auth options (KAGI_API_KEY via `apiKey.file` / `apiKey.helper`
# sops-nix pass-through) are tracked in docs/plan.md "Ideal
# architecture gate → Absorption backlog" under the MCP server
# typed-options absorption item. Source material:
# modules/mcp-servers/servers/kagi-mcp.nix.
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
  # Auth options + typed settings tracked in docs/plan.md backlog.
  options = {};
}
