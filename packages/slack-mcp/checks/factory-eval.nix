# slack-mcp contracts: an ordinary `ai.mcpServers.slack-mcp` declaration with
# the reserved `settings.token` resolves to the pool's generic http fields, and
# the pool's existing machinery delivers its bearer header on each path.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (import ../../../lib/testing/factory-harness.nix {inherit lib pkgs harness;}) mkTest;
  inherit (harness) claudeMcpServers evalDevenv evalHm mcpLib;
  inherit (import ../../kiro-cli/checks/helpers.nix {inherit lib pkgs harness;}) renderedMcpJson;
  extracted = import ../lib/extracted.nix {inherit lib;};
  manifestLib = import ../lib/manifest.nix {inherit lib;};
  mcpProxy = import ../../../lib/ai/mcpProxy.nix {inherit lib pkgs;};
  redact = import ../../../lib/redact {inherit lib;};
  token = redact.file "/run/secrets/slack-user-token";
  bearer = redact.concat ["Bearer " token];
  proxy = {
    enable = true;
    port = 9600;
  };
  # The declaration as the pool evaluates it, before and after resolution.
  declare = entry:
    (evalHm {
      ai.kiro.cli.enable = true;
      ai.mcpServers.slack-mcp = entry;
    }).config.ai.mcpServers.slack-mcp;
  resolve = mcpLib.resolveRemote "slack-mcp";
  native = resolve (declare {settings = {inherit token;};});
  proxied = resolve (declare {
    settings = {inherit token;};
    inherit proxy;
  });
  evaluates = value: (builtins.tryEval (builtins.deepSeq value true)).success;
  manifestOf = settings: manifestLib.slackManifest {inherit pkgs settings;};
  manifest = manifestOf {inherit token;};
  mcpFile = ev: ev.config.ai.kiro.files."${ev.config.ai.kiro.configDir}/settings/mcp.json";
in {
  checks =
    {
      # The same declaration renders one mcp.json template on both backends,
      # with the header as a launcher environment placeholder.
      factory-slack-mcp-backend-parity = mkTest "slack-mcp-backend-parity" (
        let
          cfg = {
            ai.kiro.cli.enable = true;
            ai.mcpServers.slack-mcp.settings = {inherit token;};
          };
          rendered = renderedMcpJson {slack-mcp = native;};
          template = builtins.unsafeDiscardStringContext "${pkgs.writeText "kiro-mcp.json" rendered}";
        in
          lib.hasInfix template (mcpFile (evalHm cfg)).content.run
          && lib.hasInfix template (mcpFile (evalDevenv cfg)).content.run
          && lib.hasInfix "_HEADER_AUTHORIZATION}" rendered
          && !(lib.hasInfix "/run/secrets/slack-user-token" rendered)
      );

      factory-slack-mcp-default-url = mkTest "slack-mcp-default-url" (
        native.type
        == "http"
        && native.url == extracted.url
        && !(native ? settings)
        && (resolve (declare {
          settings = {inherit token;};
          url = "https://slack.example.test/mcp";
        })).url
        == "https://slack.example.test/mcp"
      );

      # The field warnings judge the resolved entry: a remote server's timeout
      # is an http field, delivered or proxied, and its consumed settings are
      # not an ignored field. Fields http ignores still warn, and so does a
      # stdio entry's timeout.
      factory-slack-mcp-http-field-warnings = mkTest "slack-mcp-http-field-warnings" (
        let
          warned = entry: field:
            lib.any (lib.hasPrefix "ai.kiro.mcpServers.slack-mcp.${field} is set")
            (evalHm {
              ai.kiro.cli.enable = true;
              ai.kiro.mcpServers.slack-mcp = entry;
            }).config.warnings;
          direct = {
            settings = {inherit token;};
            timeout = 300000;
          };
          proxied = direct // {inherit proxy;};
        in
          lib.all (entry: !(warned entry "timeout") && !(warned entry "settings")) [direct proxied]
          && warned (direct // {args = ["--verbose"];}) "args"
          && warned (proxied // {env.DEBUG = "1";}) "env"
          && warned {
            command = "slack-mcp";
            timeout = 300000;
          } "timeout"
      );

      # One file printed by a flake app and a devenv task, nothing installed.
      factory-slack-mcp-manifest-app = mkTest "slack-mcp-manifest-app" (
        let
          app = manifestLib.mkManifestApp pkgs manifest;
          task = manifestLib.mkManifestTask pkgs manifest;
        in
          app.type
          == "app"
          && lib.hasPrefix "${builtins.storeDir}/" app.program
          && task.exec == app.program
          && task.description == "Print slack-mcp-manifest.yaml"
          && manifest.name == "slack-mcp-manifest.yaml"
      );

      # Read rows are selected by default and write rows are opt in: the
      # default manifest holds no `:write` scope; naming Canvas create/update adds its pair.
      factory-slack-mcp-manifest-rows = mkTest "slack-mcp-manifest-rows" (
        let
          defaults = manifest.manifest.oauth_config.scopes.user;
          withCanvas =
            (manifestOf {
              inherit token;
              manifest.writes = ["Canvas create/update"];
            }).manifest.oauth_config.scopes.user;
        in
          !(lib.any (lib.hasSuffix ":write") defaults)
          && builtins.elem "search:read.public" defaults
          && !(builtins.elem "canvases:write" defaults)
          && builtins.elem "canvases:write" withCanvas
          && builtins.elem "canvases:read" withCanvas
          && !(evaluates
            (manifestOf {
              inherit token;
              manifest.reads = ["Canvas create/update"];
            }).manifest)
      );

      # User scopes are the sorted union of the selected rows' scopes less
      # omitScopes. No token is needed or kept.
      factory-slack-mcp-manifest-scopes = mkTest "slack-mcp-manifest-scopes" (
        let
          trimmed =
            (manifestOf {
              manifest = {
                omitScopes = ["im:history" "mpim:history"];
                reads = ["Read a channel/thread" "Search users"];
                writes = ["Canvas create/update"];
              };
            }).manifest;
        in
          trimmed.oauth_config.scopes.user
          == ["canvases:read" "canvases:write" "channels:history" "groups:history" "search:read.users"]
          && trimmed.oauth_config.scopes.bot == ["users:read"]
          && trimmed.settings.org_deploy_enabled == false
          && trimmed.settings.is_mcp_enabled
          && trimmed.oauth_config.pkce_enabled
          && !(lib.hasInfix "mcp.slack.com" (builtins.toJSON manifest.manifest))
          && !(lib.hasInfix "slack-user-token" (builtins.toJSON manifest.manifest))
      );

      # A row or scope the docs do not list is refused by the option type.
      factory-slack-mcp-manifest-unknown = mkTest "slack-mcp-manifest-unknown" (
        evaluates (manifestOf {manifest.reads = ["Search users"];}).manifest
        && !(evaluates (manifestOf {manifest.reads = ["Delete workspace"];}).manifest)
        && !(evaluates (manifestOf {manifest.omitScopes = ["admin:read"];}).manifest)
      );

      factory-slack-mcp-native-bearer = mkTest "slack-mcp-native-bearer" (
        native.headers.Authorization == bearer && native.proxy == null
      );

      # The shared renderer refuses the client-held credential header, and
      # renders the proxied client entry.
      factory-slack-mcp-non-kiro-throws = mkTest "slack-mcp-non-kiro-throws" (
        !(evaluates (mcpLib.renderServer pkgs "slack-mcp" native))
        && evaluates (mcpLib.renderServer pkgs "slack-mcp" (mcpProxy.clientEntry "slack-mcp" proxied))
      );

      factory-slack-mcp-proxy-bearer = mkTest "slack-mcp-proxy-bearer" (
        proxied.proxy.headers.Authorization == bearer && !(proxied.headers ? Authorization)
      );

      # The client gets the loopback entry only, and the pool's proxy assertions
      # accept the declaration.
      factory-slack-mcp-proxy-client-entry = mkTest "slack-mcp-proxy-client-entry" (
        let
          declared = declare {
            settings = {inherit token;};
            inherit proxy;
          };
          client = (mcpProxy.lowerClientEntries {slack-mcp = declared;}).slack-mcp;
          assertions = mcpProxy.assertionsFor {
            key = "slack-mcp";
            optionPath = "ai.mcpServers";
            server = proxied;
          };
        in
          client.url
          == "http://127.0.0.1:9600/"
          && !((client.headers or {}) ? Authorization)
          && !(lib.hasInfix "mcp.slack.com" (builtins.toJSON client))
          && lib.all (a: a.assertion) assertions
          && builtins.attrNames (mcpProxy.proxiedServers {slack-mcp = declared;}) == ["slack-mcp"]
      );

      # Refused tokens: missing, plain string, and a concat (its own seal refuses
      # a nested concat). The redact.file token is the positive control.
      factory-slack-mcp-token-required = mkTest "slack-mcp-token-required" (
        evaluates native.headers
        && !(evaluates (resolve (declare {})).headers)
        && !(evaluates (resolve (declare {settings.token = "xoxp-not-a-reference";})).headers)
        && !(evaluates (resolve (declare {settings.token = bearer;})).headers)
      );
    }
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      # The declaration alone yields the one shared daemon and a credential-free
      # client entry for another runtime. Home Manager writes services as systemd
      # user units, which Darwin lacks, so the name is absent there.
      factory-slack-mcp-proxy-service = mkTest "slack-mcp-proxy-service" (
        let
          result = evalHm {
            ai = {
              claude.enable = true;
              mcpServers.slack-mcp = {
                settings = {inherit token;};
                inherit proxy;
              };
            };
          };
          services = lib.filterAttrs (name: _: lib.hasPrefix "mcp-proxy-" name) result.config.systemd.user.services;
          entry = (claudeMcpServers "hm" result).slack-mcp;
        in
          builtins.attrNames services
          == ["mcp-proxy-slack-mcp"]
          && entry.url == "http://127.0.0.1:9600/"
          && !(lib.hasInfix "/run/secrets" (builtins.toJSON entry))
      );
    };
}
