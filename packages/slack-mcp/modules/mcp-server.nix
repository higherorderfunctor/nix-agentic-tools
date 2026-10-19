# Typed settings for Slack's remote MCP server. There is no package to build:
# the server runs at Slack's documented url and the user token of the
# consumer's own Slack app authenticates it as a bearer header. `lib/mcp.nix`
# resolves an entry keyed `slack-mcp` from these settings (`meta.external`),
# so the consumer writes only
#
#   ai.mcpServers.slack-mcp = {
#     settings.token = redact.file "…";
#     proxy = {enable = true; port = 9503;};  # optional service path
#   };
{lib, ...}: let
  redact = import ../../../lib/redact {inherit lib;};
  extracted = import ../lib/extracted.nix {inherit lib;};
in {
  meta = {
    external = true;
    scope = "remote";
  };

  settingsOptions = {
    token = lib.mkOption {
      type = redact.types.redacted;
      description = ''
        The `xoxp-` user token of the consumer's Slack app, as a redact
        reference (`redact.file` or `redact.command`). Required. It is sent as
        `Authorization: Bearer <token>`.
      '';
    };
    url = lib.mkOption {
      type = lib.types.str;
      default = extracted.url;
      description = "Slack MCP endpoint, extracted from Slack's documentation. A redacted override belongs on the entry's own `url`.";
    };
  };

  settingsToHeaders = cfg: {
    Authorization = redact.concat ["Bearer " cfg.settings.token];
  };
}
