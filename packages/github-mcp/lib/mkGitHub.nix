# Factory-of-factory for github-mcp.
#
# Consumers call `lib.ai.mcpServers.mkGitHub {...}` from their config
# to produce a typed attrset that conforms to the common MCP server
# schema (type, package, command, args, env, settings, url).
#
# Typed auth options (GITHUB_PERSONAL_ACCESS_TOKEN via `token.file`
# / `token.helper` sops-nix pass-through) are tracked in
# docs/plan.md "Ideal architecture gate → Absorption backlog" under
# the MCP server typed-options absorption item. Source material:
# modules/mcp-servers/servers/github-mcp.nix (181 lines).
{
  lib,
  pkgs,
  ...
}:
lib.ai.mcpServer.mkMcpServer {
  name = "github";
  defaults = {
    package = pkgs.ai.github-mcp;
    type = "stdio";
    command = "github-mcp-server";
    args = [];
  };
  # Auth options + typed settings tracked in docs/plan.md backlog.
  options = {};
}
