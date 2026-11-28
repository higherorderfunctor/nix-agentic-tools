# cspell:ignore materializers
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
  inherit (harness) checkRows claudeMcpServers evalDevenv evalHm mcpLib rejectsChange;
  manifestLib = import ../lib/manifest.nix {inherit lib;};
  mcpProxy = import ../../../lib/ai/mcpProxy.nix {inherit lib pkgs;};
  redact = import ../../../lib/redact {inherit lib;};
  endpoint = "https://mcp.slack.com/mcp";
  loopback = "http://127.0.0.1:9600/";
  tokenPath = "/run/secrets/slack-user-token";
  token = redact.file tokenPath;
  bearer = {_redact.concat = ["Bearer " {_redact.file = tokenPath;}];};
  proxy = {
    enable = true;
    port = 9600;
  };
  direct = {settings = {inherit token;};};
  viaProxy = direct // {inherit proxy;};
  kiroConfig = entry: {
    ai.kiro.cli.enable = true;
    ai.mcpServers.slack-mcp = entry;
  };
  # The declaration as the pool evaluates it, before and after resolution.
  declare = entry: (evalHm (kiroConfig entry)).config.ai.mcpServers.slack-mcp;
  resolve = mcpLib.resolveRemote "slack-mcp";
  declaredProxy = {slack-mcp = declare viaProxy;};
  proxied = resolve declaredProxy.slack-mcp;
  manifestOf = settings: manifestLib.slackManifest {inherit pkgs settings;};
  scopesOf = selection: (manifestOf {manifest = selection;}).manifest.oauth_config.scopes.user;
  descriptionOf = args:
    (manifestLib.slackManifest ({
        inherit pkgs;
        settings = {};
      }
      // args)).manifest.display_information.description;
  manifest = manifestOf direct.settings;
  canvas = {writes = ["Canvas create/update"];};
  mcpFile = ev: ev.config.ai.kiro.files."${ev.config.ai.kiro.configDir}/settings/mcp.json";
in {
  checks =
    {
      # Check the actual materializers against a fixed client document, not a
      # second call to Kiro's renderer. The template must carry no token path.
      factory-slack-mcp-backend-parity = mkTest "slack-mcp-backend-parity" (
        let
          expected = builtins.toJSON {
            mcpServers.slack-mcp = {
              headers.Authorization = "\${env:KIRO_MCP_SLACK_MCP_HEADER_AUTHORIZATION}";
              type = "http";
              url = endpoint;
            };
          };
          template = builtins.unsafeDiscardStringContext "${pkgs.writeText "kiro-mcp.json" expected}";
          usesTemplate = evaluate: lib.hasInfix template (mcpFile (evaluate (kiroConfig direct))).content.run;
        in
          checkRows "Slack Kiro template delivery" {
            "Home Manager writes the template with a launcher placeholder, not a token path" = usesTemplate evalHm;
            "devenv writes the same placeholder template instead of omitting the root declaration" = usesTemplate evalDevenv;
          }
      );

      factory-slack-mcp-default-url = mkTest "slack-mcp-default-url" (
        let
          override = "https://slack.example.test/mcp";
        in
          checkRows "Slack remote resolution" {
            "an explicit entry URL wins over the owner default" = (resolve (declare (direct // {url = override;}))).url == override;
          }
      );

      # The field warnings judge the resolved entry: a remote server's timeout
      # is an http field, delivered or proxied, and its consumed settings are
      # not an ignored field. Fields http ignores still warn.
      factory-slack-mcp-http-field-warnings = mkTest "slack-mcp-http-field-warnings" (
        let
          warnings = entry:
            (evalHm {
              ai.kiro.cli.enable = true;
              ai.kiro.mcpServers.slack-mcp = entry;
            }).config.warnings;
          warned = messages: field: lib.any (lib.hasPrefix "ai.kiro.mcpServers.slack-mcp.${field} is set") messages;
          nativeHttp = direct // {timeout = 300000;};
          proxiedHttp = nativeHttp // {inherit proxy;};
          nativeWarnings = warnings nativeHttp;
          proxyWarnings = warnings proxiedHttp;
        in
          checkRows "Slack Kiro ignored-field warnings" {
            "HTTP env warns on the proxy path" = warned (warnings (proxiedHttp // {env.DEBUG = "1";})) "env";
            "direct HTTP does not warn about consumed settings" = !(warned nativeWarnings "settings");
            "proxied HTTP does not warn about consumed settings or a supported timeout" = !(warned proxyWarnings "settings" || warned proxyWarnings "timeout");
          }
      );

      # One file printed by a flake app and a devenv task, nothing installed.
      factory-slack-mcp-manifest-app = mkTest "slack-mcp-manifest-app" (
        let
          app = manifestLib.mkManifestApp pkgs manifest;
          task = manifestLib.mkManifestTask pkgs manifest;
        in
          checkRows "Slack manifest printer registration" {
            "devenv executes the same printer as the app" = task.exec == app.program;
            "the flake app supplies a store executable" = app.type == "app" && lib.hasPrefix "${builtins.storeDir}/" app.program;
          }
      );

      # The description names what the selection grants, an override is kept
      # verbatim, and Slack's 140-character limit is refused at evaluation.
      factory-slack-mcp-manifest-description = mkTest "slack-mcp-manifest-description" (
        let
          limit = lib.concatStrings (lib.replicate 140 "x");
        in
          checkRows "Slack manifest description" {
            "a 141-character description is refused while 140 characters pass" =
              rejectsChange
              (description: descriptionOf {inherit description;}) {
                expected = limit;
                invalid = limit + "x";
                valid = limit;
              };
            "the default description does not claim write access" = descriptionOf {} == "Personal MCP token acting as its user: read-only. The bot user never posts.";
            "the generated description names the Canvas write grant" = descriptionOf {settings.manifest = canvas;} == "Personal MCP token acting as its user: read-only except Canvas create/update. The bot user never posts.";
          }
      );

      # Read rows are selected by default and write rows are opt in. Force each
      # enum through the same merge as the manifest; forcing generated scopes
      # instead could mistake an unknown row's failed lookup for type rejection.
      factory-slack-mcp-manifest-rows = mkTest "slack-mcp-manifest-rows" (
        let
          readSelection = field: selection: (mcpLib.evalSettings "slack-mcp" {manifest = selection;}).manifest.${field};
          reads = ["Search users"];
          omitScopes = ["search:read.users"];
        in
          checkRows "Slack manifest row selection" {
            "a read-only row cannot be opted in as a write row" = rejectsChange (readSelection "writes") {
              expected = canvas.writes;
              invalid = {writes = reads;};
              valid = canvas;
            };
            "an unknown read row is rejected instead of being ignored" = rejectsChange (readSelection "reads") {
              expected = reads;
              invalid = {reads = ["Delete workspace"];};
              valid = {inherit reads;};
            };
            "an unknown scope in omitScopes is rejected instead of being ignored" = rejectsChange (readSelection "omitScopes") {
              expected = omitScopes;
              invalid = {omitScopes = ["admin:read"];};
              valid = {inherit omitScopes;};
            };
            "default selection grants every documented read scope and no writes" =
              scopesOf {}
              == [
                "channels:history"
                "channels:read"
                "emoji:read"
                "files:read"
                "groups:history"
                "groups:read"
                "im:history"
                "im:read"
                "mpim:history"
                "mpim:read"
                "reactions:read"
                "search:read.files"
                "search:read.im"
                "search:read.mpim"
                "search:read.private"
                "search:read.public"
                "search:read.users"
                "users:read"
                "users:read.email"
              ];
            "putting the Canvas write row under reads is rejected" = rejectsChange (readSelection "reads") {
              expected = reads;
              invalid = {reads = ["Canvas create/update"];};
              valid = {inherit reads;};
            };
          }
      );

      # User scopes are the sorted union of the selected rows' scopes less
      # omitScopes. No token is needed or kept.
      factory-slack-mcp-manifest-scopes = mkTest "slack-mcp-manifest-scopes" (
        let
          trimmed =
            (manifestOf {
              manifest =
                canvas
                // {
                  omitScopes = ["im:history" "mpim:history"];
                  reads = ["Read a channel/thread" "Search users"];
                };
            }).manifest;
          json = builtins.toJSON manifest.manifest;
        in
          checkRows "Slack app manifest fields" {
            "MCP is enabled so the app can use the server" = trimmed.settings.is_mcp_enabled;
            "PKCE is enabled for authorization" = trimmed.oauth_config.pkce_enabled;
            "a configured token and the server endpoint do not leak into the app manifest" = !(lib.hasInfix tokenPath json || lib.hasInfix "mcp.slack.com" json);
            "the bot stub requests only users:read" = trimmed.oauth_config.scopes.bot == ["users:read"];
            "the personal app is not deployed across the organization" = !trimmed.settings.org_deploy_enabled;
            "Canvas opt-in adds both scopes while omitScopes removes only the selected history scopes" = trimmed.oauth_config.scopes.user == ["canvases:read" "canvases:write" "channels:history" "groups:history" "search:read.users"];
          }
      );

      # The daemon needs the exact Bearer value to authenticate to Slack.
      factory-slack-mcp-proxy-bearer = mkTest "slack-mcp-proxy-bearer" (proxied.proxy.headers.Authorization == bearer);

      # The client gets the loopback entry only, and the pool's proxy assertions
      # accept the declaration.
      factory-slack-mcp-proxy-client-entry = mkTest "slack-mcp-proxy-client-entry" (
        let
          client = (mcpProxy.lowerClientEntries declaredProxy).slack-mcp;
          expectedClient = {
            type = "http";
            url = loopback;
          };
          assertions = mcpProxy.assertionsFor {
            key = "slack-mcp";
            optionPath = "ai.mcpServers";
            server = proxied;
          };
        in
          checkRows "Slack proxy lowering" {
            "a resolved Slack upstream passes validation rather than appearing to lack a URL" = lib.all (a: a.assertion) assertions;
            "lowering retains neither the upstream nor its bearer in the shared client pool" = client == expectedClient;
          }
      );

      # Force the merged token directly for missing/plaintext values. Only the
      # already-composed reference reaches the outer Bearer concat's refusal.
      factory-slack-mcp-token-required = mkTest "slack-mcp-token-required" (
        let
          readToken = entry: (mcpLib.evalSettings "slack-mcp" (declare entry).settings).token;
        in
          checkRows "Slack token restrictions" {
            "a literal token is rejected at the typed setting instead of being accepted" = rejectsChange readToken {
              expected = token;
              invalid.settings.token = "xoxp-not-a-reference";
              valid = direct;
            };
            "a missing token is rejected instead of receiving a default" = rejectsChange readToken {
              expected = token;
              invalid = {};
              valid = direct;
            };
            "an already-composed token cannot become a nested Bearer reference" = rejectsChange (entry: (resolve (declare entry)).headers.Authorization) {
              expected = bearer;
              invalid.settings.token = bearer;
              valid = direct;
            };
          }
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
              mcpServers.slack-mcp = viaProxy;
            };
          };
          services = lib.filterAttrs (name: _: lib.hasPrefix "mcp-proxy-" name) result.config.systemd.user.services;
          entry = (claudeMcpServers "hm" result).slack-mcp;
        in
          checkRows "Slack Home Manager proxy delivery" {
            "Claude receives loopback without the token path" = entry.url == loopback && !((entry.headers or {}) ? Authorization) && !(lib.hasInfix tokenPath (builtins.toJSON entry));
            "enabling the typed declaration creates one shared daemon, not zero or a per-runtime copy" = builtins.attrNames services == ["mcp-proxy-slack-mcp"];
          }
      );
    };
}
