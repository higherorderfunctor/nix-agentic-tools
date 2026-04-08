# Factory-of-factory for kagi-mcp.
#
# Consumers call `lib.ai.mcpServers.mkKagi {...}` from their config
# to produce a typed attrset that conforms to the common MCP server
# schema (type, package, command, args, env, settings, url).
#
# This is a newer API under `lib.ai.mcpServers.*`. It is SEPARATE from
# the live, consumer-facing `lib.mkStdioEntry` / `lib.loadServer`
# path which already has working typed settings + auth
# (`KAGI_API_KEY` via `settings.credentials.file` /
# `settings.credentials.helper` sops-nix pass-through) declared in
# `modules/mcp-servers/servers/kagi-mcp.nix`. nixos-config uses the
# `lib.mkStdioEntry` path today at the sentinel commit `f341bcb`:
#
#   kagi-mcp = inputs.nix-agentic-tools.lib.mkStdioEntry pkgs {
#     package = pkgs.nix-mcp-servers.kagi-mcp;
#     settings.credentials.file =
#       config.sops.secrets."${username}-kagi-api-key".path;
#   };
#
# See docs/plan.md `A5` (port typed MCP server option schemas into
# per-package dirs) for the relocation plan.
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
  # Typed settings + auth live in modules/mcp-servers/servers/kagi-mcp.nix,
  # consumed via lib.mkStdioEntry. A5 relocates that module to
  # packages/kagi-mcp/modules/mcp-server.nix.
  options = {};
}
