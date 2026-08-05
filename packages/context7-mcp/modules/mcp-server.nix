{
  lib,
  mcpLib,
  ...
}: let
  inherit (lib) mkOption types optionalAttrs optionals;
in {
  meta = {
    modes = {
      stdio = "context7-mcp --transport stdio";
      # Native HTTP requires Upstash Redis and exposes no bind-address knob.
      # Bridge the working stdio transport so the shared mcp-proxy owns the
      # listener and makes service.host load-bearing.
      http = "bridge";
    };
    scope = "remote";
    defaultPort = 19750;
    credentialVars = {
      credentials = {
        envVar = "CONTEXT7_API_KEY";
        required = false;
      };
    };
    tools = ["query-docs" "resolve-library-id"];
  };

  settingsOptions = {
    credentials = mcpLib.mkCredentialsOption "CONTEXT7_API_KEY";

    path = mkOption {
      type = types.str;
      default = "/mcp";
      description = "HTTP endpoint path. Only used in HTTP mode.";
    };

    apiUrl = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Override the base URL for the Context7 API.";
    };
  };

  settingsToEnv = cfg: _mode:
    optionalAttrs (cfg.settings.apiUrl != null) {
      CONTEXT7_API_URL = cfg.settings.apiUrl;
    };

  settingsToArgs = cfg: mode:
    optionals (mode == "http") ["--port" (toString cfg.service.port)];
}
