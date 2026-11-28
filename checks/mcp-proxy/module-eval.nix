# End-to-end module contracts; the shared harness discovers every backend.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  redact = import ../../lib/redact {inherit lib;};
  inherit (import ../../lib/testing/mcp-fixtures.nix {inherit lib pkgs harness;}) mcpProxyLib proxySampleServer;
  inherit (harness) checkRows claudeMcpPath claudeMcpServers evalDevenv evalHm launchdAgentRunsLauncher mcpLib mkTest rejectsChange;
  inherit (import ../../packages/chatgpt-codex/checks/helpers.nix {inherit lib pkgs harness;}) hmCodexSettings;
  sampleCaddyfile = mcpProxyLib.caddyfileFor (mcpProxyLib.specFor "example" proxySampleServer);
  proxyServices = services: lib.filterAttrs (name: _: lib.hasPrefix "mcp-proxy-" name) services;
  failedAssertions = result: map (item: item.message) (builtins.filter (item: !item.assertion) result.config.assertions);
  webexResult = backend: clients: assignServers:
    (
      if backend == "hm"
      then harness.evalHmModules
      else harness.evalDevenvModules
    ) [
      ({config, ...}: {
        ai = {
          claude.enable = clients;
          codex.enable = clients;
          mcpServers = lib.mkIf assignServers config.ai.webex-mcp.mcpServers;
          webex-mcp.instances = {
            disabled.enable = false;
            personal = {
              enable = true;
              oauth = {
                clientId = redact.file "/run/secrets/personal-id";
                clientSecret = redact.file "/run/secrets/personal-secret";
              };
            };
            work = {
              enable = true;
              oauth = {
                clientId = redact.file "/run/secrets/work-id";
                clientSecret = redact.file "/run/secrets/work-secret";
              };
            };
          };
        };
      })
    ];
  webexServers = [
    "webex-mcp-personal-meeting"
    "webex-mcp-personal-messaging"
    "webex-mcp-work-meeting"
    "webex-mcp-work-messaging"
  ];
  webexShared = backend: let
    result = webexResult backend true true;
    cfg = result.config;
    accounts = cfg.ai.mcp-oauth.accounts;
    clients = {
      Claude = claudeMcpServers backend result;
      Codex = (hmCodexSettings result).mcp_servers;
    };
  in
    {
      "account names exclude the disabled instance" =
        builtins.attrNames accounts == ["webex-mcp-personal" "webex-mcp-work"];
      "enabling both clients does not create a conflicting claim" = failedAssertions result == [];
      "one daemon and port per endpoint, one OAuth service per account" =
        builtins.attrNames (proxyServices cfg.ai.services)
        == [
          "mcp-proxy-webex-mcp-personal-meeting"
          "mcp-proxy-webex-mcp-personal-messaging"
          "mcp-proxy-webex-mcp-work-meeting"
          "mcp-proxy-webex-mcp-work-messaging"
        ]
        && builtins.attrNames cfg.ai.mcp-oauth.services
        == [
          "mcp-oauth-webex-mcp-personal"
          "mcp-oauth-webex-mcp-work"
        ]
        && lib.all (port: builtins.hasAttr port cfg.ai.claims.port) ["19592" "19593" "19594" "19595"];
      "root endpoint names exclude the disabled instance" = builtins.attrNames cfg.ai.mcpServers == webexServers;
    }
    # Both backends import the same Webex declarations and OAuth mount.
    // lib.optionalAttrs (backend == "hm") {
      "account mapping does not cross instances" =
        map (name: cfg.ai.mcpServers.${name}.proxy.oauthAccount) webexServers
        == [
          "webex-mcp-personal"
          "webex-mcp-personal"
          "webex-mcp-work"
          "webex-mcp-work"
        ];
      "each OAuth account has its own login, files, provider and scopes" = lib.all (instance: let
        account = accounts."webex-mcp-${instance}" or null;
      in
        account
        != null
        && account.clientId == redact.file "/run/secrets/${instance}-id"
        && account.clientSecret == redact.file "/run/secrets/${instance}-secret"
        && account.login
        == {
          inherit instance;
          owner = "webex-mcp";
          profile = "webex";
        }
        && account.provider
        == {
          authorizeUrl = "https://webexapis.com/v1/authorize";
          extraScopes = ["spark:kms"];
          loginLifetimeDays = 90;
          tokenUrl = "https://webexapis.com/v1/access_token";
        }
        && account.scopes
        == [
          "meeting:participants_read"
          "meeting:schedules_read"
          "meeting:summaries_read"
          "meeting:transcripts_read"
          "spark:mcp"
          "spark:memberships_read"
          "spark:messages_read"
          "spark:people_read"
          "spark:rooms_read"
        ]) ["personal" "work"];
      "root declarations target the right Webex endpoint, not a client URL" =
        map (name: cfg.ai.mcpServers.${name}.url or null) webexServers
        == [
          "https://mcp.webexapis.com/mcp/webex-meeting"
          "https://mcp.webexapis.com/mcp/webex-messaging"
          "https://mcp.webexapis.com/mcp/webex-meeting"
          "https://mcp.webexapis.com/mcp/webex-messaging"
        ];
    }
    // lib.mapAttrs' (name: client:
      lib.nameValuePair "${name} receives each endpoint's loopback URL" (
        builtins.attrNames client
        == webexServers
        && map (server: client.${server}.url) webexServers
        == [
          "http://127.0.0.1:19592/"
          "http://127.0.0.1:19593/"
          "http://127.0.0.1:19594/"
          "http://127.0.0.1:19595/"
        ]
      ))
    clients;
  webexUnused = backend: let
    ownerOnly = (webexResult backend true false).config;
    evaluate =
      if backend == "hm"
      then evalHm
      else evalDevenv;
    noOAuth = result: let
      packages =
        if backend == "hm"
        then result.config.home.packages
        else result.config.packages;
    in
      result.config.ai.mcpServers
      == {}
      && result.config.ai.webex-mcp.mcpServers == {}
      && result.config.ai.mcp-oauth.accounts == {}
      && result.config.ai.mcp-oauth.services == {}
      && !(lib.any (package: builtins.elem package.name ["mcp-oauth" "mcp-oauth-logins"]) packages);
  in
    {
      "an absent declaration does not eagerly allocate OAuth resources" = noOAuth (evaluate {});
      # Enabled owner instances must not populate the consumer's root pool.
      "owner declarations stay local until the consumer assigns them" =
        ownerOnly.ai.mcpServers == {} && builtins.attrNames ownerOnly.ai.webex-mcp.mcpServers == webexServers;
    }
    // lib.optionalAttrs (backend == "devenv") {
      "declarations without enabled clients do not start a proxy" =
        proxyServices (webexResult backend false true).config.ai.services == {};
    };
in {
  checks =
    {
      # The guard is the point of the change, so exercise it as SHELL rather
      # than as a grep: run a generated snippet against a genuinely empty file
      # and against a populated one. A grep proves the line was emitted; only
      # running it proves the line works. A nonempty prefix and suffix must
      # not hide the failure of a file nested in the concatenation.
      module-credential-empty-guard-aborts = let
        # `redact.assign` bakes the path in at generation time and the test
        # needs two different files, so the path is a placeholder substituted
        # per-case below.
        runner = pkgs.writeShellScript "empty-guard-runner" ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          export PATH="${pkgs.coreutils}/bin"
          ${redact.assign {
            inherit pkgs;
            option = "TEST_TOKEN";
            variable = "TEST_TOKEN";
            value = redact.concat ["Bearer " (redact.file "/run/redact-test-secret") " suffix"];
            export = true;
          }}
          [[ $TEST_TOKEN == 'Bearer a-real-token suffix' ]]
          echo "REACHED-PROGRAM"
        '';
      in
        pkgs.runCommand "module-test-credential-empty-guard-aborts" {
          nativeBuildInputs = [pkgs.gnused];
        } ''
          # stdenv's buildCommand already runs with errexit, pipefail AND
          # inherit_errexit on (measured against the pinned nixpkgs), so this
          # line is not what makes a failing assertion below fail the build.
          # It adds the three stdenv deliberately leaves off — `-u`, `-E`, `-T`
          # — and brings the snippet in line with the repo-wide strict-mode
          # rule. Verified safe here: setting them inside a buildCommand does
          # not upset the phases stdenv runs afterwards.
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :

          : > empty
          printf 'a-real-token' > full

          run_case() {
            sed "s|/run/redact-test-secret|$PWD/$1|" ${runner} > case.sh
            ${pkgs.bash}/bin/bash case.sh
          }

          # Positive control: rejecting every path must not pass.
          got=$(run_case full 2>&1)
          [ "$got" = "REACHED-PROGRAM" ] || {
            echo "FAIL: populated secret was rejected (got: $got)" >&2
            exit 1
          }

          if got=$(run_case empty 2>&1); then
            echo "FAIL: empty secret did not abort the wrapper (got: $got)" >&2
            exit 1
          fi
          if [ "$got" != "TEST_TOKEN: reference resolved empty" ]; then
            echo "FAIL: empty secret did not abort via the expected guard (got: $got)" >&2
            exit 1
          fi

          echo PASS > "$out"
        '';

      # Kiro preprocesses credential-valued URLs and headers before the shared
      # renderer. Other runtimes must not serialize an unresolved reference.
      module-mcp-credential-non-kiro = mkTest "mcp-credential-non-kiro" (
        let
          literal = {
            type = "http";
            url = "https://example.invalid/";
            headers.H = "public";
          };
          render = mcpLib.renderServer pkgs "example";
        in
          checkRows "shared HTTP renderer rejects unresolved credentials" {
            "credential header is rejected instead of serialized" = rejectsChange (server: (render server).headers.H) {
              valid = literal;
              invalid = literal // {headers.H = redact.file "/run/secrets/header";};
              expected = "public";
            };
            "credential URL is rejected instead of serialized" = rejectsChange (server: (render server).url) {
              valid = literal;
              invalid = literal // {url = redact.file "/run/secrets/url";};
              expected = "https://example.invalid/";
            };
          }
      );

      # `admin off` does not disable Caddy's config autosave. Exercise the
      # packaged binary against isolated dummy XDG homes: the historical variant
      # must write the adapted config (including the dummy credential), while the
      # generated Caddyfile must not create autosave.json at all. The vulnerable
      # control proves this check fails for the pre-fix rendering.
      module-mcp-proxy-caddy-autosave-disabled = let
        vulnerableCaddyfile = pkgs.writeText "mcp-proxy-example-vulnerable-Caddyfile" (
          lib.replaceStrings ["persist_config off"] [""] (builtins.readFile sampleCaddyfile)
        );
      in
        pkgs.runCommand "module-test-mcp-proxy-caddy-autosave-disabled" {
          nativeBuildInputs = [pkgs.caddy pkgs.coreutils pkgs.jq];
        } ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :

          run_caddy() {
            local config="$1"
            local xdg_root="$2"
            mkdir -p "$xdg_root/config" "$xdg_root/data"
            local status=0
            env \
              MCP_PROXY_EXAMPLE_ORIGIN=https://example.invalid \
              MCP_PROXY_EXAMPLE_PATH=/mcp \
              MCP_PROXY_EXAMPLE_HEADER_X_API_KEY=DUMMY-CREDENTIAL-autosave-check \
              MCP_PROXY_EXAMPLE_HEADER_X_SERVICE_TOKEN=DUMMY-CREDENTIAL-service-check \
              XDG_CONFIG_HOME="$xdg_root/config" \
              XDG_DATA_HOME="$xdg_root/data" \
              timeout 2 caddy run --config "$config" --adapter caddyfile \
                >"$xdg_root/caddy.log" 2>&1 || status=$?
            if [[ $status != 124 ]]; then
              printf 'FAIL: Caddy exited %s before timeout: %s\n' "$status" "$config" >&2
              cat "$xdg_root/caddy.log" >&2
              return 1
            fi
          }

          run_caddy ${vulnerableCaddyfile} "$TMPDIR/vulnerable"
          vulnerable_autosave="$TMPDIR/vulnerable/config/caddy/autosave.json"
          jq -e \
            '.. | strings | select(contains("DUMMY-CREDENTIAL-autosave-check"))' \
            "$vulnerable_autosave" >/dev/null
          echo "vulnerable variant: autosave PRESENT with dummy credential"

          run_caddy ${sampleCaddyfile} "$TMPDIR/fixed"
          test ! -e "$TMPDIR/fixed/config/caddy/autosave.json"
          echo "fixed rendering: autosave ABSENT"

          touch "$out"
        '';

      # An empty delete list renders an unfiltered global log, which writes
      # every request header to the journal, so the shared helper throws.
      module-mcp-proxy-caddy-empty-log-deletes-throws = mkTest "mcp-proxy-caddy-empty-log-deletes-throws" (
        let
          inherit (import ../../lib/ai/caddy.nix {inherit lib pkgs;}) globalBlock;
        in
          checkRows "Caddy request log redaction" {
            "empty delete list cannot render an unfiltered log" =
              rejectsChange
              (logDeletes: lib.hasInfix "request>headers delete" (globalBlock {inherit logDeletes;})) {
                valid = ["request>headers"];
                invalid = [];
                expected = true;
              };
          }
      );

      # Caddy's site address is only a Host-header matcher: it does NOT
      # replace `bind`. The golden pins the actual loopback bind, runtime
      # placeholders (not credentials), deletion and transport directives.
      module-mcp-proxy-caddyfile-golden = mkTest "mcp-proxy-caddyfile-golden" (
        sampleCaddyfile.text == builtins.readFile ./example.Caddyfile
      );

      # The golden uses both credential headers and explicit edits. With only
      # a credential URL, defaults still must not rewrite client identity.
      # Whole-map redaction must apply even without startup credentials: a
      # per-field denylist would miss customer headers, and Caddy's built-in
      # redaction only covers certain standard names.
      module-mcp-proxy-caddyfile-has-no-secrets = mkTest "mcp-proxy-caddyfile-has-no-secrets" (
        let
          server = proxySampleServer // {proxy = proxySampleServer.proxy // {headers = {};};};
          render = source: (mcpProxyLib.caddyfileFor (mcpProxyLib.specFor "example" source)).text;
          cf = render server;
          literalCaddyfile = render (server // {url = "https://example.invalid/mcp";});
        in
          checkRows "proxy with no header declarations" {
            "credential URL is not written into the Caddyfile" =
              lib.hasInfix "reverse_proxy {$MCP_PROXY_EXAMPLE_ORIGIN}" cf
              && lib.hasInfix "rewrite * {$MCP_PROXY_EXAMPLE_PATH}" cf
              && !(lib.hasInfix "/run/secrets" cf);
            # These are client defaults; stripping them makes requests more distinctive.
            "no default rewrite or deletion of client identity headers" =
              !(lib.any (line: builtins.match ".*header_up [-+?]?(user-agent|accept-language|sec-fetch-mode)([[:space:]].*)?" (lib.toLower line) != null) (lib.splitString "\n" cf));
            "no startup credentials still delete the whole request-header map" =
              lib.hasInfix "format filter" literalCaddyfile
              && lib.hasInfix "request>headers delete" literalCaddyfile
              && !(lib.hasInfix "request>headers>" literalCaddyfile);
          }
      );

      # An IPv6 loopback bind must still hand clients a parseable URL: the
      # literal goes in brackets in the url, while Caddy's `bind` keeps it bare.
      module-mcp-proxy-client-entry-brackets-ipv6 = mkTest "mcp-proxy-client-entry-brackets-ipv6" (
        let
          server = lib.recursiveUpdate proxySampleServer {proxy.host = "::1";};
        in
          (mcpProxyLib.clientEntry "example" server).url
          == "http://[::1]:9501/"
          && lib.hasInfix "bind ::1\n" (mcpProxyLib.caddyfileFor (mcpProxyLib.specFor "example" server)).text
      );

      # Exact client records pin both halves of the split: daemon fields
      # must never escape, and literal client headers must remain usable.
      module-mcp-proxy-client-entry = mkTest "mcp-proxy-client-entry" (
        let
          render = mcpProxyLib.clientEntry "example";
          clientHeaders."X-Client-Sent" = "yes";
          expected = {
            timeout = 300000;
            type = "http";
            url = "http://127.0.0.1:9501/";
          };
        in
          checkRows "proxy client entry" {
            "adding a client header does not expose daemon headers" =
              render (proxySampleServer // {headers = clientHeaders;}) == (expected // {headers = clientHeaders;});
            "credential URL and daemon fields are replaced without losing the client timeout" =
              render proxySampleServer == expected;
          }
      );

      # Top-level headers belong to the client, not the proxy. Moving the
      # credential to proxy.headers must clear the assertion without banning
      # ordinary client headers. evalHm returns the assertions without enforcing
      # them, so an eval throw is not evidence of the expected rejection.
      module-mcp-proxy-client-header-restrictions = mkTest "mcp-proxy-client-header-restrictions" (
        let
          failed = header:
            failedAssertions (evalHm {
              ai.kiro = {
                cli.enable = true;
                mcpServers.jira = {
                  type = "http";
                  url = redact.file "/run/secrets/jira-url";
                  headers."X-Client-Sent" = header;
                  proxy = {
                    enable = true;
                    port = 9501;
                    headers."X-Jira-Token" = redact.file "/run/secrets/service-token";
                  };
                };
              };
            });
        in
          checkRows "proxied Kiro client headers" {
            "credential header names its migration destination" = let
              failures = failed (redact.file "/run/secrets/client-token");
              message = builtins.head failures;
            in
              builtins.length failures
              == 1
              && lib.hasInfix "put a CREDENTIAL in the server's top-level `headers`" message
              && lib.hasInfix "Move them to `proxy.headers`" message;
            "literal client header and separate proxy credential pass" = failed "yes" == [];
          }
      );

      # A root-owned proxy must emit a runnable devenv process, not just a
      # client entry pointing at a local port that nothing listens on.
      module-mcp-proxy-devenv-emits-process = mkTest "mcp-proxy-devenv-emits-process" (
        let
          result = evalDevenv {
            ai = {
              claude.enable = true;
              mcpServers.shared = proxySampleServer;
            };
          };
        in
          lib.all (assertion: assertion.assertion) result.config.assertions
          && lib.hasSuffix "/bin/ai-service-mcp-proxy-shared" result.config.processes.mcp-proxy-shared.exec
      );

      module-mcp-proxy-header-variable-collision = mkTest "mcp-proxy-header-variable-collision" (
        let
          one = redact.file "/run/secrets/one";
          two = redact.file "/run/secrets/two";
          readSecrets = second:
            (mcpProxyLib.specFor "example" {
              url = "https://example.invalid/mcp";
              proxy = {
                host = "127.0.0.1";
                port = 9501;
                headers = {
                  "X-Key" = one;
                  "${second}" = two;
                };
              };
            }).headerSecrets;
        in
          checkRows "proxy startup credential variables" {
            "different headers cannot map to the same variable" = rejectsChange readSecrets {
              valid = "X-Other";
              invalid = "X_Key";
              expected = {
                MCP_PROXY_EXAMPLE_HEADER_X_KEY = one;
                MCP_PROXY_EXAMPLE_HEADER_X_OTHER = two;
              };
            };
          }
      );

      # `proxy.host` takes a bare address: the client URL brackets IPv6 itself,
      # so a pre-bracketed host would render `[[::1]]`, and a `%` zone suffix is
      # neither a valid URL authority nor a usable `bind`.
      module-mcp-proxy-host-refuses-brackets-and-zones = mkTest "mcp-proxy-host-refuses-brackets-and-zones" (
        let
          readHost = host:
            (evalHm {
              ai.mcpServers.example = lib.recursiveUpdate proxySampleServer {proxy.host = host;};
            }).config.ai.mcpServers.example.proxy.host;
          rejectHost = invalid:
            rejectsChange readHost {
              inherit invalid;
              valid = "::1";
              expected = "::1";
            };
        in
          checkRows "proxy host merge" {
            "rejects a bracketed IPv6 address" = rejectHost "[::1]";
            "rejects a scoped IPv6 address" = rejectHost "fe80::1%eth0";
            "rejects an empty address" = rejectHost "";
            # Keeping the bracket and zone restrictions alone still allows an
            # address to split into multiple arguments to Caddy's bind.
            "rejects whitespace inside an address" = rejectHost "bad host";
          }
      );

      # Claims, not incidental Nix merge errors, reject two owners of the
      # same proxy. Identical declarations must still count as two owners.
      module-mcp-proxy-owner-key-collisions = mkTest "mcp-proxy-owner-key-collisions" (
        let
          failures = ai:
            failedAssertions (evalHm {
              ai =
                ai
                // {
                  claude = {
                    enable = true;
                    mcpServers.shared = proxySampleServer;
                  };
                };
            });
          expected = other: [
            "ai.claims.port.9501: claimed by claude:mcp-proxy-shared.ports.main and ${other}:mcp-proxy-shared.ports.main"
            "ai.claims.service.mcp-proxy-shared: claimed by claude and ${other}"
          ];
        in
          checkRows "proxy service and port claims" {
            "root and runtime owners cannot share a service key or port" =
              failures {
                codex.enable = true;
                mcpServers.shared = proxySampleServer;
              }
              == expected "internal";
            "two runtime owners cannot share a service key or port" =
              failures {
                kiro = {
                  cli.enable = true;
                  mcpServers.shared = proxySampleServer;
                };
              }
              == expected "kiro";
          }
      );

      # The launcher resolves the upstream url (a secret or a literal), then
      # the proxy's run script splits it into the origin and path Caddy needs,
      # points Caddy's state at a per-proxy runtime directory and execs it. An
      # empty startup token must abort before execution. The stand-in Caddy
      # observes argv and environment separately: only the latter may contain
      # a startup credential, and a second launch must reread its file.
      module-mcp-proxy-run-script-splits-url-and-isolates-state = let
        services = import ../../packages/ai-module/lib/services.nix {inherit lib;};
        strictShellApplication = import ../../lib/strict-shell-application.nix;
        urlReader = strictShellApplication pkgs {
          name = "mcp-proxy-test-url";
          text = ''
            printf 'https://upstream.example.test/path'
          '';
        };
        caddy = strictShellApplication pkgs {
          name = "caddy";
          text = ''
            env | ${pkgs.gnugrep}/bin/grep -E '^MCP_PROXY_[A-Z]+_(HEADER_X_SERVICE_TOKEN|ORIGIN|PATH)=' | ${pkgs.coreutils}/bin/sort
            printf '%s\n' "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$@"
          '';
        };
        proxyLib = import ../../lib/ai/mcpProxy.nix {
          inherit lib;
          pkgs = pkgs // {inherit caddy;};
        };
        launcher = name: url: headers:
          services.mkLauncher {
            inherit pkgs;
            name = "mcp-proxy-${name}";
            entry =
              (proxyLib.serviceFor name {
                inherit url;
                proxy = proxySampleServer.proxy // {inherit headers;};
              })
              // {files = {};};
          };
        secret = launcher "secret" (redact.command (lib.getExe urlReader)) {
          "X-Service-Token" = redact.file "/run/proxy-test-token";
        };
        plain = launcher "plain" "https://upstream.example.test" {};
      in
        pkgs.runCommandLocal "mcp-proxy-run-script-splits-url-and-isolates-state" {} ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          export XDG_RUNTIME_DIR="$TMPDIR/runtime"
          ${pkgs.coreutils}/bin/mkdir -p "$XDG_RUNTIME_DIR"
          # Substitute only the fixture's runtime path, not the emitted
          # variable, reader or launch command.
          ${pkgs.gnused}/bin/sed "s|/run/proxy-test-token|$TMPDIR/token|" \
            ${secret}/bin/ai-service-mcp-proxy-secret > secret-launcher
          run_secret() { ${pkgs.bash}/bin/bash secret-launcher; }

          check_launch() {
            local name=$1 origin=$2 path=$3
            shift 3
            local state="$XDG_RUNTIME_DIR/mcp-proxy-$name"
            {
              if [[ $# != 0 ]]; then printf 'MCP_PROXY_SECRET_HEADER_X_SERVICE_TOKEN=%s\n' "$1"; fi
              printf '%s\n' "$origin" "$path" "$state/config" "$state/data" run --config \
                "<mcp-proxy-$name-Caddyfile>" --adapter caddyfile
            } > expected
            # Match the store path's name, not its independently irrelevant hash.
            ${pkgs.gnused}/bin/sed -E 's|^${builtins.storeDir}/[a-z0-9]+-(mcp-proxy-[a-z]+-Caddyfile)$|<\1>|' actual > normalized
            ${pkgs.diffutils}/bin/diff -u --label "$name expected" --label "$name actual" expected normalized
            test "$(${pkgs.coreutils}/bin/stat -c %a "$state")" = 700
          }

          ${plain}/bin/ai-service-mcp-proxy-plain > actual
          check_launch plain MCP_PROXY_PLAIN_ORIGIN=https://upstream.example.test MCP_PROXY_PLAIN_PATH=/
          for token in first-dummy-token rotated-dummy-token; do
            printf '%s' "$token" > "$TMPDIR/token"
            run_secret > actual
            check_launch secret MCP_PROXY_SECRET_ORIGIN=https://upstream.example.test MCP_PROXY_SECRET_PATH=/path "$token"
          done

          : > "$TMPDIR/token"
          if run_secret > failed 2> error; then
            echo "an empty startup token started the proxy" >&2
            exit 1
          fi
          test ! -s failed
          ${pkgs.gnugrep}/bin/grep -Fx 'ai.services.mcp-proxy-secret.environment.MCP_PROXY_SECRET_HEADER_X_SERVICE_TOKEN: reference resolved empty' error
          touch "$out"
        '';
    }
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      # Four endpoints are shared across clients but credentials must follow
      # their owning Webex account; unused accounts and daemons must stay lazy.
      module-mcp-proxy-webex-wiring = mkTest "mcp-proxy-webex-wiring" (
        let
          rows = backend: lib.mapAttrs' (name: value: lib.nameValuePair "${backend}: ${name}" value) (webexShared backend // webexUnused backend);
        in
          checkRows "Webex proxy ownership and account routing" (rows "devenv" // rows "hm")
      );

      # A runtime-scoped declaration is that runtime's service, so a disabled
      # runtime runs no proxy and claims nothing.
      module-mcp-proxy-disabled-runtime-owner-emits-nothing = mkTest "mcp-proxy-disabled-runtime-owner-emits-nothing" (
        let
          result = evalHm {
            ai.claude.mcpServers.direct = proxySampleServer;
          };
        in
          !(result.config.systemd.user.services ? mcp-proxy-direct)
          && result.config.ai.claims.service == {}
          && claudeMcpServers "hm" result == {}
          && !(result.config.home.file ? ${claudeMcpPath "hm"})
      );

      # Positive control for the ownership failure: two direct owners with distinct
      # keys produce two ordinary service units.
      module-mcp-proxy-distinct-owner-keys-pass = mkTest "mcp-proxy-distinct-owner-keys-pass" (
        let
          result = evalHm {
            ai = {
              claude = {
                enable = true;
                mcpServers.alpha = proxySampleServer;
              };
              kiro = {
                cli.enable = true;
                mcpServers.beta = lib.recursiveUpdate proxySampleServer {
                  proxy.port = 9502;
                };
              };
            };
          };
        in
          builtins.attrNames (proxyServices result.config.systemd.user.services)
          == ["mcp-proxy-alpha" "mcp-proxy-beta"]
          && failedAssertions result == []
      );

      # A runtime's ordinary same-key replacement remains normal pool precedence,
      # not a proxy-ownership collision. Another runtime may still inherit the
      # top-level owner, which is materialized once for that consumer.
      module-mcp-proxy-non-proxy-runtime-replacement-preserves-shared-owner = mkTest "mcp-proxy-non-proxy-runtime-replacement-preserves-shared-owner" (
        let
          result = evalHm {
            ai = {
              claude = {
                enable = true;
                mcpServers.shared = {
                  type = "http";
                  url = "https://runtime.example.test/mcp";
                };
              };
              codex.enable = true;
              mcpServers.shared = proxySampleServer;
            };
          };
          claudeEntry = (claudeMcpServers "hm" result).shared;
          codexEntry = (hmCodexSettings result).mcp_servers.shared;
        in
          result.config.systemd.user.services ? mcp-proxy-shared
          && claudeEntry.url == "https://runtime.example.test/mcp"
          && codexEntry.url == "http://127.0.0.1:9501/"
      );

      # A runtime-scoped declaration owns its managed proxy directly and receives
      # the matching lowered client entry. Its unit does not depend on a top-level
      # declaration or on accidental cross-runtime module-definition deduplication.
      module-mcp-proxy-runtime-owner-emits-directly = mkTest "mcp-proxy-runtime-owner-emits-directly" (
        let
          result = evalHm {
            ai.claude = {
              enable = true;
              mcpServers.direct = proxySampleServer;
            };
          };
          entry = (claudeMcpServers "hm" result).direct;
        in
          result.config.systemd.user.services ? mcp-proxy-direct
          && entry.url == "http://127.0.0.1:9501/"
      );

      # A top-level proxied declaration owns ONE shared daemon. The runtimes see
      # only the credential-free client entry, so enabling a second consumer must
      # neither duplicate the service nor expose the owner record.
      module-mcp-proxy-top-level-owner-is-shared = mkTest "mcp-proxy-top-level-owner-is-shared" (
        let
          result = evalHm {
            ai = {
              claude.enable = true;
              codex.enable = true;
              mcpServers.shared = proxySampleServer;
            };
          };
          services = proxyServices result.config.systemd.user.services;
          claudeEntry = (claudeMcpServers "hm" result).shared;
          codexEntry = (hmCodexSettings result).mcp_servers.shared;
          rendered = builtins.toJSON [claudeEntry codexEntry];
        in
          builtins.attrNames services
          == ["mcp-proxy-shared"]
          && claudeEntry.url == "http://127.0.0.1:9501/"
          && codexEntry.url == "http://127.0.0.1:9501/"
          && !(claudeEntry ? proxy)
          && !(codexEntry ? proxy)
          && !(lib.hasInfix "/run/secrets" rendered)
          && !(lib.hasInfix "X-Service-Token" rendered)
      );

      # Follow the command emitted by the module, not a freshly rendered
      # script. A correctly named script can still use the wrong declaration.
      module-mcp-proxy-unit-uses-services-launcher = let
        result = evalHm {
          ai.kiro = {
            cli.enable = true;
            mcpServers.jira = lib.recursiveUpdate proxySampleServer {proxy.host = "127.0.0.2";};
          };
        };
        unit = result.config.systemd.user.services.mcp-proxy-jira;
        service = result.config.ai.services.mcp-proxy-jira;
      in
        assert checkRows "Kiro Jira proxy service" {
          "binds only daemon credentials to the launcher's environment" =
            service.environment
            == {
              MCP_PROXY_JIRA_HEADER_X_API_KEY = redact.concat ["Bearer " (redact.file "/run/secrets/api-key")];
              MCP_PROXY_JIRA_HEADER_X_SERVICE_TOKEN = redact.file "/run/secrets/service-token";
              MCP_PROXY_JIRA_URL = redact.file "/run/secrets/upstream-url";
            };
          "uses the services launcher without unit environment" =
            lib.hasSuffix "/bin/ai-service-mcp-proxy-jira" unit.Service.ExecStart
            && !(unit.Service ? Environment);
        };
          pkgs.runCommandLocal "module-test-mcp-proxy-unit-uses-services-launcher" {
            nativeBuildInputs = [pkgs.gnugrep pkgs.gnused];
            proxyCommand = builtins.head service.command;
            unitLauncher = unit.Service.ExecStart;
          } ''
            set -euETo pipefail
            shopt -s inherit_errexit 2>/dev/null || :

            grep -Fx ${lib.escapeShellArg "exec ${lib.escapeShellArg (builtins.head service.command)}"} "$unitLauncher"
            grep -Fx '_url="''${MCP_PROXY_JIRA_URL}"' "$proxyCommand"
            caddyfile=$(sed -n 's/^exec .* run --config \([^ ]*\) --adapter caddyfile$/\1/p' "$proxyCommand")
            grep -Fx ':9501 {' "$caddyfile"
            grep -Fx $'\tbind 127.0.0.2' "$caddyfile"
            grep -F 'rewrite * {$MCP_PROXY_JIRA_PATH}' "$caddyfile"
            grep -F 'reverse_proxy {$MCP_PROXY_JIRA_ORIGIN} {' "$caddyfile"
            grep -F 'header_up X-Api-Key "{$MCP_PROXY_JIRA_HEADER_X_API_KEY}"' "$caddyfile"
            grep -F 'header_up X-Route "primary"' "$caddyfile"
            grep -F 'header_up X-Service-Token "{$MCP_PROXY_JIRA_HEADER_X_SERVICE_TOKEN}"' "$caddyfile"
            grep -F 'header_up -X-Drop-Me' "$caddyfile"
            touch "$out"
          '';

      # A top-level owner is lazy: if every enabled capable runtime replaces or
      # tombstones the key, no client can reach it and no managed daemon exists.
      module-mcp-proxy-unused-top-level-owner-is-not-materialized = mkTest "mcp-proxy-unused-top-level-owner-is-not-materialized" (
        let
          result = evalHm {
            ai = {
              claude = {
                enable = true;
                mcpServers.unused = null;
              };
              mcpServers.unused = proxySampleServer;
            };
          };
        in
          !(result.config.systemd.user.services ? mcp-proxy-unused)
          && !(claudeMcpServers "hm" result ? unused)
      );
    }
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
      # Fails when the proxy daemon is missing from launchd or runs something other than its launcher.
      module-mcp-proxy-darwin-launchd = mkTest "mcp-proxy-darwin-launchd" (
        let
          result = evalHm {
            ai.claude = {
              enable = true;
              mcpServers.example = proxySampleServer;
            };
          };
        in
          result.config.systemd.user.services
          == {}
          && launchdAgentRunsLauncher result.config "mcp-proxy-example"
      );
    };
}
