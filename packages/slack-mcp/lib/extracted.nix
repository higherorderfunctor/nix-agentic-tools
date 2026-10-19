# Slack's documented MCP endpoint and tool-to-scope table, read from the drift-checked sidecar
# `packages/slack-mcp/extracted/` as an ordinary committed file. Never read the
# check's `passthru.extracted` derivation here: that is import-from-derivation.
{lib}: let
  inherit (import ../../../lib/extracted/facts.nix {inherit lib;}) get load;
  inherit (load {dir = ../extracted;}) aggregate;
in {
  tools = get aggregate "tools";
  url = get aggregate "url";
}
