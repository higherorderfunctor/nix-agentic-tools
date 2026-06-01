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
      # FIXME(context7 >=3.0.0): the `http` transport unconditionally builds a
      # Redis-backed session store at startup (createSessionStore -> getRedis in
      # dist/index.js) and aborts with "Upstash Redis credentials are required"
      # unless UPSTASH_REDIS_REST_URL + UPSTASH_REDIS_REST_TOKEN are set. This is
      # wired for upstream's hosted/NGINX deployment, not local self-hosting, so
      # running this mode without an Upstash instance crash-loops the service.
      # The `stdio` mode above skips the session store entirely and is the
      # working default. To make `http` usable when self-hosting we'd need to
      # surface the UPSTASH_* vars via credentialVars below (required only in
      # http mode) and document standing up a (Upstash-compatible) Redis.
      http = "context7-mcp --transport http";
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
