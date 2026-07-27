# Factory-of-factory for aihubmix-mcp.
#
# Consumers call `lib.ai.mcpServers.mkAihubmix {...}` from their config
# to produce a typed attrset that conforms to the common MCP server
# schema (type, package, command, args, env, settings, url).
#
# The server reads its credential from the AIHUBMIX_API_KEY environment
# variable at startup and refuses to serve tools without it. It is NOT
# declared as a typed `settings.credentials` option here: the common
# schema's `env` passthrough is the live surface, and the repo's
# credential handling (runtime `cat` of a sops-managed file, never a
# store-baked secret) is supplied by `lib.ai.mkStdioEntry` /
# `lib.mcp.nix`. See packages/kagi-mcp/lib/mkKagi.nix for the same
# split and docs/plan.md `A5` for the relocation plan.
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
