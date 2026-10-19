# Slack's documented MCP endpoint, read from the drift-checked sidecar
# `packages/slack-mcp/extracted/` as an ordinary committed file. Never read the
# check's `passthru.extracted` derivation here: that is import-from-derivation.
{lib}: let
  inherit (import ../../../lib/extracted/facts.nix {inherit lib;}) get load;
  inherit (load {dir = ../extracted;}) aggregate;
in {
  url = get aggregate "url";
}
