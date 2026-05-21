# Factory-of-factory for gitlab-mcp.
#
# Consumers call `lib.ai.mcpServers.mkGitlab {...}` from their config
# to produce a typed attrset that conforms to the common MCP server
# schema (type, package, command, args, env, settings, url).
#
# This intentionally mirrors the github-mcp / kagi-mcp factory stub
# (options = {}). The typed settings + auth surface lives in
# packages/gitlab-mcp/modules/mcp-server.nix, consumed via
# lib.ai.mkStdioEntry / lib.ai.loadServer. When the factory-factory
# DRY gap (see memory: project_factory_known_gaps.md) gets fixed, this
# stub moves with the rest of the cohort in one sweep instead of
# needing a separate catch-up.
{
  lib,
  pkgs,
  ...
}:
lib.ai.mcpServer.mkMcpServer {
  name = "gitlab";
  defaults = {
    package = pkgs.ai.mcpServers.gitlab-mcp;
    type = "stdio";
    command = "gitlab-mcp";
    args = [];
  };
  options = {};
}
