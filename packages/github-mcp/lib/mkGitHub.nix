# Factory-of-factory for github-mcp.
#
# Consumers call `lib.ai.mcpServers.mkGitHub {...}` from their config
# to produce a typed attrset that conforms to the common MCP server
# schema (type, package, command, args, env, settings, url).
#
# This is a newer API under `lib.ai.mcpServers.*`. It is SEPARATE from
# the live, consumer-facing `lib.ai.mkStdioEntry` / `lib.ai.loadServer`
# path which already has working typed settings + auth
# (`GITHUB_PERSONAL_ACCESS_TOKEN` via `settings.credentials = rv.file` /
# `settings.credentials = rv.helper` sops-nix pass-through) declared in
# `packages/github-mcp/modules/mcp-server.nix`.
#
# Whichever consumer path the factory factory lands on, the auth
# pattern (`rv.file` / `rv.helper`
# projected through `mkSecretsWrapper` at runtime) is the
# authoritative surface.
{
  lib,
  pkgs,
  ...
}:
lib.ai.mcpServer.mkMcpServer {
  name = "github";
  defaults = {
    package = pkgs.ai.mcpServers.github-mcp;
    type = "stdio";
    command = "github-mcp-server";
    args = [];
  };
  options = {};
}
