# Factory-of-factory for aihubmix-mcp.
#
# Consumers call `lib.ai.mcpServers.mkAihubmix {...}` from their config
# to produce a typed attrset that conforms to the common MCP server
# schema (type, package, command, args, env, settings, url).
#
# The server reads AIHUBMIX_API_KEY at startup and refuses tools without it.
# Use `env.AIHUBMIX_API_KEY = redact.file {path = "/run/secrets/aihubmix";};`
# (or redact.command). The shared MCP renderer reads the reference at launch;
# only the reference path enters the store. There is no settings.credentials.
{
  lib,
  pkgs,
  ...
}:
lib.ai.mcpServer.mkMcpServer {
  name = "aihubmix";
  defaults = {
    package = pkgs.ai.mcpServers.aihubmix-mcp;
    type = "stdio";
    command = "aihubmix-mcp";
    args = [];
  };
  # No custom options — aihubmix-mcp has no config knobs beyond the common
  # schema plus environment variables in `env`: AIHUBMIX_API_KEY (required),
  # and since 1.1.0 the optional AIHUBMIX_BASE_URL (origin only, no `/v1`;
  # defaults to https://aihubmix.com) and AIHUBMIX_VIDEO_POLL_TIMEOUT_MS
  # (the video_generate poll budget, default 480000). Promote one to a typed
  # option only when a consumer actually needs it declaratively.
  options = {};
}
