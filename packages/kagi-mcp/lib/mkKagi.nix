# Factory-of-factory for kagi-mcp.
#
# Consumers call `lib.ai.mcpServers.mkKagi {...}` from their config
# to produce a typed attrset that conforms to the common MCP server
# schema (type, package, command, args, env, settings, url).
#
# This is a newer API under `lib.ai.mcpServers.*`. It is SEPARATE from
# the live, consumer-facing `lib.ai.mkStdioEntry` / `lib.ai.loadServer`
# path which already has working typed settings + auth
# (`KAGI_API_KEY` via `settings.credentials = rv.file` /
# `settings.credentials = rv.helper` sops-nix pass-through) declared in
# `packages/kagi-mcp/modules/mcp-server.nix`.
{
  lib,
  pkgs,
  ...
}:
lib.ai.mcpServer.mkMcpServer {
  name = "kagi";
  defaults = {
    package = pkgs.ai.mcpServers.kagi-mcp;
    type = "stdio";
    command = "kagimcp";
    args = [];
  };
  options = {};
}
