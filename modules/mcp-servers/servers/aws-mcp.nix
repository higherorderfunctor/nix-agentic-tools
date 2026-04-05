{lib, ...}: let
  inherit (lib) mkOption types;
in {
  meta = {
    modes = {http = "external";};
    scope = "remote";
    defaultPort = null;
    external = true;
    tools = [];
  };

  settingsOptions = {
    url = mkOption {
      type = types.str;
      default = "https://knowledge-mcp.global.api.aws";
      description = "URL of the AWS Knowledge MCP server.";
    };
  };

  settingsToEnv = _cfg: _mode: {};
  settingsToArgs = _cfg: _mode: [];
}
