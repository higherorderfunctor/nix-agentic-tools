# Factory-of-factory for github-mcp.
#
# Consumers call `lib.ai.mcpServers.mkGitHub {...}` from their config
# to produce a typed attrset that conforms to the common MCP server
# schema (type, package, command, args, env, settings, url).
#
# This is a newer API under `lib.ai.mcpServers.*`. It is SEPARATE from
# the live, consumer-facing `lib.mkStdioEntry` / `lib.loadServer`
# path which already has working typed settings + auth
# (`GITHUB_PERSONAL_ACCESS_TOKEN` via `settings.credentials.file` /
# `settings.credentials.helper` sops-nix pass-through) declared in
# `modules/mcp-servers/servers/github-mcp.nix`. nixos-config uses
# the `lib.mkStdioEntry` path today at the sentinel commit
# `f341bcb`:
#
#   github-mcp = inputs.nix-agentic-tools.lib.mkStdioEntry pkgs {
#     package = pkgs.nix-mcp-servers.github-mcp;
#     settings.credentials.file =
#       config.sops.secrets."${username}-github-api-key".path;
#   };
#
# Whichever consumer path the factory factory lands on, the auth
# pattern (`mcpLib.mkCredentialsOption "GITHUB_PERSONAL_ACCESS_TOKEN"`
# projected through `mkSecretsWrapper` at runtime) is the
# authoritative surface. See docs/plan.md `A5` (port typed MCP server
# option schemas into per-package dirs) for the relocation plan.
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
  # Typed settings + auth live in modules/mcp-servers/servers/github-mcp.nix,
  # consumed via lib.mkStdioEntry. A5 relocates that module to
  # packages/github-mcp/modules/mcp-server.nix.
  options = {};
}
