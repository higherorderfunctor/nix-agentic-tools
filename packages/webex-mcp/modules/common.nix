{
  config,
  lib,
  ...
}: let
  oauth = (import ../../mcp-oauth/lib/mount.nix {inherit lib;}).mkOAuthMount {
    owner = "webex-mcp";
    profile = {
      authorizeUrl = "https://webexapis.com/v1/authorize";
      extraScopes = ["spark:kms"];
      loginLifetimeDays = 90;
      name = "webex";
      scopes = [
        "meeting:participants_read"
        "meeting:schedules_read"
        "meeting:summaries_read"
        "meeting:transcripts_read"
        "spark:mcp"
        "spark:memberships_read"
        "spark:messages_read"
        "spark:people_read"
        "spark:rooms_read"
      ];
      tokenUrl = "https://webexapis.com/v1/access_token";
    };
  };
  instances = lib.filterAttrs (_: instance: instance.enable) config.ai.webex-mcp.instances;
in {
  imports = [oauth.module];
  options.ai.webex-mcp = {
    instances = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options.enable = lib.mkEnableOption "both remote servers for this instance";
      });
    };
    mcpServers = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule (import ../../../lib/ai/mcpServer/commonSchema.nix));
      readOnly = true;
      description = "Generated Webex server entries for consumers to assign to ai.mcpServers.";
    };
  };
  config.ai.webex-mcp.mcpServers = builtins.listToAttrs (lib.concatLists (lib.imap0 (index: instance:
    lib.imap0 (offset: endpoint:
      lib.nameValuePair "webex-mcp-${instance}-${endpoint}" {
        url = "https://mcp.webexapis.com/mcp/webex-${endpoint}";
        proxy = {
          enable = true;
          oauthAccount = oauth.accountName instance;
          port = 19592 + index * 2 + offset;
        };
      }) ["meeting" "messaging"])
  (builtins.attrNames instances)));
}
