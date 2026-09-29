# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode sembleignore
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (import ../../lib/testing/mcp-fixtures.nix {inherit lib pkgs harness;}) mcpProxyLib proxySampleServer;
  inherit (harness) claudeMcpPath claudeMcpServers evalDevenv evalHm mcpLib mkTest;
  inherit (import ../../packages/chatgpt-codex/checks/helpers.nix {inherit lib pkgs harness;}) hmCodexSettings;
in {
  checks = {
    # Kiro content pipeline: a credential http HEADER renders to a
    # `${env:VAR}` placeholder (Kiro expands it at launch) and a credential
    # URL to a bare `${VAR}` envsubst sentinel (WE expand it at activation)
    # — the raw secret file path is NEVER serialized, and the `Bearer `
    # header prefix + `https://` url prefix compose. Content-level (the
    # shared render both backends feed into). See mcpSecrets.nix.
    # ── Local credential-injecting proxy (lib/ai/mcpProxy.nix) ─────────

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
        services = lib.filterAttrs (name: _: lib.hasPrefix "mcp-proxy-" name) result.config.systemd.user.services;
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
        && !(entry ? proxy)
    );

    # "Directly" means declaration lifetime, not enabled-client lifetime. This
    # preserves the existing runtime-owner contract while moving ownership out
    # of the per-runtime fanout transform.
    module-mcp-proxy-disabled-runtime-owner-emits-directly = mkTest "mcp-proxy-disabled-runtime-owner-emits-directly" (
      let
        result = evalHm {
          ai.claude.mcpServers.direct = proxySampleServer;
        };
      in
        result.config.systemd.user.services ? mcp-proxy-direct
        && claudeMcpServers "hm" result == {}
        && !(result.config.home.file ? ${claudeMcpPath "hm"})
    );

    # The MCP key is the managed-unit ownership key. Reusing it at two runtime
    # scopes must produce the dedicated actionable assertion and must suppress
    # the conflicted unit so a generic module merge error cannot hide it.
    module-mcp-proxy-reused-owner-key-fails-explicitly = mkTest "mcp-proxy-reused-owner-key-fails-explicitly" (
      let
        result = evalHm {
          ai = {
            claude.mcpServers.shared = proxySampleServer;
            kiro.mcpServers.shared = lib.recursiveUpdate proxySampleServer {
              proxy.port = 9502;
            };
          };
        };
        failed = builtins.filter (assertion: !assertion.assertion) result.config.assertions;
      in
        !(result.config.systemd.user.services ? mcp-proxy-shared)
        && builtins.any
        (assertion:
          lib.hasInfix "MCP proxy ownership keys are reused" assertion.message
          && lib.hasInfix "ai.claude.mcpServers.shared" assertion.message
          && lib.hasInfix "ai.kiro.mcpServers.shared" assertion.message
          && lib.hasInfix "different MCP server key" assertion.message)
        failed
    );

    # The ownership namespace spans declaration layers, not just sibling
    # runtimes: a top-level owner and a runtime-direct owner cannot share a key.
    module-mcp-proxy-root-runtime-reused-owner-key-fails-explicitly = mkTest "mcp-proxy-root-runtime-reused-owner-key-fails-explicitly" (
      let
        result = evalHm {
          ai = {
            mcpServers.shared = proxySampleServer;
            claude.mcpServers.shared = lib.recursiveUpdate proxySampleServer {
              proxy.port = 9502;
            };
          };
        };
        failed = builtins.filter (assertion: !assertion.assertion) result.config.assertions;
      in
        !(result.config.systemd.user.services ? mcp-proxy-shared)
        && builtins.any
        (assertion:
          lib.hasInfix "MCP proxy ownership keys are reused" assertion.message
          && lib.hasInfix "ai.mcpServers.shared" assertion.message
          && lib.hasInfix "ai.claude.mcpServers.shared" assertion.message)
        failed
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
        failed = builtins.filter (assertion: !assertion.assertion) result.config.assertions;
      in
        result.config.systemd.user.services ? mcp-proxy-shared
        && claudeEntry.url == "https://runtime.example.test/mcp"
        && codexEntry.url == "http://127.0.0.1:9501/"
        && builtins.all
        (assertion: !(lib.hasInfix "MCP proxy ownership keys are reused" assertion.message))
        failed
    );

    # Positive control for the ownership failure: two direct owners with distinct
    # keys produce two units and no ownership assertion.
    module-mcp-proxy-distinct-owner-keys-pass = mkTest "mcp-proxy-distinct-owner-keys-pass" (
      let
        result = evalHm {
          ai = {
            claude.mcpServers.alpha = proxySampleServer;
            kiro.mcpServers.beta = lib.recursiveUpdate proxySampleServer {
              proxy.port = 9502;
            };
          };
        };
        failed = builtins.filter (assertion: !assertion.assertion) result.config.assertions;
      in
        result.config.systemd.user.services ? mcp-proxy-alpha
        && result.config.systemd.user.services ? mcp-proxy-beta
        && builtins.all
        (assertion: !(lib.hasInfix "MCP proxy ownership keys are reused" assertion.message))
        failed
    );

    # Devenv lifecycle remains deliberately separate. A used top-level owner is
    # lowered for the client model but still fails rather than silently omitting
    # the managed process that would make its loopback URL live.
    module-mcp-proxy-devenv-lifecycle-remains-rejected = mkTest "mcp-proxy-devenv-lifecycle-remains-rejected" (
      let
        result = evalDevenv {
          ai = {
            claude.enable = true;
            mcpServers.shared = proxySampleServer;
          };
        };
        failed = builtins.filter (assertion: !assertion.assertion) result.config.assertions;
      in
        builtins.any
        (assertion:
          lib.hasInfix "ai.mcpServers" assertion.message
          && lib.hasInfix "backend does not implement" assertion.message
          && lib.hasInfix "devenv lifecycle is tracked separately" assertion.message)
        failed
    );

    # The property under test is NEGATIVE and easy to regress silently: a
    # proxied server must hand the client NOTHING secret. Assert the
    # loopback url is there AND that no header, no secret path, and no
    # placeholder survives into the entry.
    module-mcp-proxy-client-entry-drops-credentials = mkTest "mcp-proxy-client-entry-drops-credentials" (
      let
        entry = mcpProxyLib.clientEntry "example" proxySampleServer;
        json = builtins.toJSON entry;
      in
        entry.url
        == "http://127.0.0.1:9501/"
        && entry.type == "http"
        # `timeout` is client behavior, not a credential — it must survive.
        && entry.timeout == 300000
        # The fixture declares its credentials under `proxy.headers`, which
        # the daemon injects and the client never sees. Nothing from there
        # may appear in the entry.
        && !(entry ? headers)
        && !(lib.hasInfix "/run/secrets" json)
        && !(lib.hasInfix "Bearer" json)
        && !(lib.hasInfix "env:" json)
        && !(lib.hasInfix "X-Api-Key" json)
        && !(lib.hasInfix "X-Service-Token" json)
    );

    # Top-level `headers` on a proxied server are the CLIENT's and DO reach
    # it — that is the half of the split which makes the two keys mean
    # different things instead of one key meaning two. Dropping them here
    # would be a silent no-op on config the operator wrote.
    #
    # Safe only because `mkBackendTransform` asserts they carry no
    # credential; that assertion is tested separately below.
    module-mcp-proxy-client-entry-keeps-client-headers = mkTest "mcp-proxy-client-entry-keeps-client-headers" (
      let
        entry = mcpProxyLib.clientEntry "example" (proxySampleServer
          // {
            headers."X-Client-Sent" = "yes";
          });
      in
        entry.headers."X-Client-Sent"
        == "yes"
        # ... and still nothing the daemon injects.
        && !(lib.hasInfix "X-Api-Key" (builtins.toJSON entry))
    );

    # The Caddyfile lands in the WORLD-READABLE Nix store, so it may carry
    # only `{$VAR}` tokens. This also pins the escaping trap: Nix's `$${`
    # is an escape for a literal `${`, so a regression here silently emits
    # an unexpanded `{${VAR}}` that Caddy would forward verbatim.
    module-mcp-proxy-caddyfile-has-no-secrets = mkTest "mcp-proxy-caddyfile-has-no-secrets" (
      let
        cf = builtins.readFile (mcpProxyLib.caddyfileFor (mcpProxyLib.specFor "example" proxySampleServer));
      in
        # `bind <host>` is the ONLY thing that restricts the listener to an
        # interface, and it is the assertion that matters most here: the
        # endpoint is unauthenticated, so a wildcard listener publishes use
        # of the upstream credential to the whole network.
        #
        # Do NOT weaken this to a site-address check like
        # `hasInfix "127.0.0.1:9501 {"`. That string is satisfied by a
        # config that still listens on every interface — in Caddy a site
        # address host is a Host-HEADER matcher, not a bind — so such a
        # test goes green on the insecure config. Measured.
        lib.hasInfix "bind 127.0.0.1" cf
        && lib.hasInfix "persist_config off" cf
        && lib.hasInfix "{$MCP_PROXY_EXAMPLE_X_SERVICE_TOKEN}" cf
        && lib.hasInfix "Bearer {$MCP_PROXY_EXAMPLE_X_API_KEY}" cf
        && lib.hasInfix "{$MCP_PROXY_EXAMPLE_ORIGIN}" cf
        && lib.hasInfix "{$MCP_PROXY_EXAMPLE_PATH}" cf
        # Plain-string headers are not secrets and stay literal.
        && lib.hasInfix ''header_up X-Route "primary"'' cf
        # Streaming: without this, SSE responses buffer to the end.
        && lib.hasInfix "flush_interval -1" cf
        # Caddy adds these four on its own and they must be deleted, not
        # merely overwritten. Measured — the `Via` header is NOT covered by
        # dropping the X-Forwarded-* trio.
        && lib.hasInfix "header_up -Via" cf
        && lib.hasInfix "header_up -X-Forwarded-For" cf
        && lib.hasInfix "header_up -X-Forwarded-Host" cf
        && lib.hasInfix "header_up -X-Forwarded-Proto" cf
        # A null `proxy.headers` value is a DELETION, not an injection.
        && lib.hasInfix "header_up -X-Drop-Me" cf
        && !(lib.hasInfix ''header_up X-Drop-Me "'' cf)
        # The proxy must NOT touch the client's identity. These were added
        # 2026-08-12 and removed 2026-08-13 after measurement: the headers
        # are undici defaults identifying Node, not a harness, and stripping
        # them made the request MORE distinctive. Asserted negatively so a
        # reintroduction has to argue with this comment first.
        && !(lib.hasInfix "header_up User-Agent" cf)
        && !(lib.hasInfix "header_up -Accept-Language" cf)
        && !(lib.hasInfix "header_up -Sec-Fetch-Mode" cf)
        # Go's transport adds `Accept-Encoding: gzip` below the header
        # layer, so no `header_up -` can reach it; only turning transport
        # compression off keeps the request identical to the client's.
        && lib.hasInfix "compression off" cf
        && !(lib.hasInfix "/run/secrets" cf)
        # The escape regression: an unexpanded Nix interpolation token.
        && !(lib.hasInfix "{\${" cf)
    );

    # `admin off` does not disable Caddy's config autosave. Exercise the
    # packaged binary against isolated dummy XDG homes: the historical variant
    # must write the adapted config (including the dummy credential), while the
    # generated Caddyfile must not create autosave.json at all. The vulnerable
    # control proves this check fails for the pre-fix rendering.
    module-mcp-proxy-caddy-autosave-disabled = let
      fixedCaddyfile = mcpProxyLib.caddyfileFor (mcpProxyLib.specFor "example" proxySampleServer);
      vulnerableCaddyfile = pkgs.writeText "mcp-proxy-example-vulnerable-Caddyfile" (
        lib.replaceStrings ["persist_config off"] [""] (builtins.readFile fixedCaddyfile)
      );
    in
      pkgs.runCommand "module-test-mcp-proxy-caddy-autosave-disabled" {
        nativeBuildInputs = [pkgs.caddy pkgs.coreutils pkgs.jq];
      } ''
        caddy fmt --diff ${fixedCaddyfile}

        run_caddy() {
          local config="$1"
          local xdg_root="$2"
          mkdir -p "$xdg_root/config" "$xdg_root/data"
          set +e
          env \
            MCP_PROXY_EXAMPLE_ORIGIN=https://example.invalid \
            MCP_PROXY_EXAMPLE_PATH=/mcp \
            MCP_PROXY_EXAMPLE_X_API_KEY=DUMMY-CREDENTIAL-autosave-check \
            MCP_PROXY_EXAMPLE_X_SERVICE_TOKEN=DUMMY-CREDENTIAL-service-check \
            XDG_CONFIG_HOME="$xdg_root/config" \
            XDG_DATA_HOME="$xdg_root/data" \
            timeout 2 caddy run --config "$config" --adapter caddyfile \
              >"$xdg_root/caddy.log" 2>&1
          local status=$?
          set -e
          test "$status" -eq 124
        }

        run_caddy ${vulnerableCaddyfile} "$TMPDIR/vulnerable"
        vulnerable_autosave="$TMPDIR/vulnerable/config/caddy/autosave.json"
        test -f "$vulnerable_autosave"
        jq -e \
          '.. | strings | select(contains("DUMMY-CREDENTIAL-autosave-check"))' \
          "$vulnerable_autosave" >/dev/null
        echo "vulnerable variant: autosave PRESENT with dummy credential"

        run_caddy ${fixedCaddyfile} "$TMPDIR/fixed"
        test ! -e "$TMPDIR/fixed/config/caddy/autosave.json"
        echo "fixed rendering: autosave ABSENT"

        touch "$out"
      '';

    # Caddy's reverse_proxy ERROR logs embed the whole request header map,
    # and its built-in `log_credentials` covers only Authorization/Cookie —
    # never the custom auth headers this proxy injects. Measured 2026-08-12:
    # 35 journal lines carrying a live gateway API key.
    #
    # The fix drops the WHOLE MAP rather than naming secret fields. Asserted
    # that way on purpose: a per-field list is a denylist that fails OPEN on
    # any header nobody enumerated, so a test pinning field names would bless
    # exactly the shape being avoided.
    module-mcp-proxy-log-drops-whole-header-map = mkTest "mcp-proxy-log-drops-whole-header-map" (
      let
        cf = builtins.readFile (mcpProxyLib.caddyfileFor (mcpProxyLib.specFor "example" proxySampleServer));
      in
        lib.hasInfix "format filter" cf
        && lib.hasInfix "request>headers delete" cf
        # No per-field redaction anywhere — that is the regression.
        && !(lib.hasInfix "request>headers>" cf)
    );

    # Unconditional: a proxy injecting no credential still drops headers. A
    # conditional filter would make the safe posture depend on the server's
    # shape, so ADDING a credential later would silently flip logging from
    # safe to leaky — the failure mode being designed out.
    module-mcp-proxy-log-drop-is-unconditional = mkTest "mcp-proxy-log-drop-is-unconditional" (
      let
        cf = builtins.readFile (mcpProxyLib.caddyfileFor (mcpProxyLib.specFor "example" {
          type = "http";
          url = "https://example.invalid/mcp";
          proxy = {
            enable = true;
            host = "127.0.0.1";
            port = 9501;
          };
        }));
      in
        lib.hasInfix "request>headers delete" cf
        && !(lib.hasInfix "format console" cf)
    );

    # A credential in a PROXIED server's top-level `headers` must be a hard
    # error, not an absorption. Those headers go to the client, so absorbing
    # them silently (the pre-2026-08-13 behavior) made one key mean two
    # things, and passing them through would hand the client the credential
    # the proxy exists to withhold. The assertion is also the migration
    # message for config written against the old shape.
    module-mcp-proxy-credential-in-client-headers-throws = mkTest "mcp-proxy-credential-in-client-headers-throws" (
      let
        result =
          builtins.tryEval
          (evalHm {
            ai.kiro = {
              enable = true;
              mcpServers.jira = {
                type = "http";
                url.file = "/run/secrets/jira-url";
                # WRONG on purpose: belongs under proxy.headers.
                headers."X-Jira-Token".file = "/run/secrets/service-token";
                proxy = {
                  enable = true;
                  port = 9501;
                };
              };
            };
          })
      .config.assertions;
        failed =
          if result.success
          then builtins.filter (a: !a.assertion) result.value
          else [];
      in
        # Require the eval to SUCCEED and the failing assertion to be OURS.
        #
        # Accepting a throw here instead (`!result.success || …`) is what
        # this originally did, and it was wrong: `evalHm` returns
        # `config.assertions` WITHOUT checking them, so a failed assertion
        # never throws — the throw branch could only ever be reached by an
        # unrelated evaluation error, which it would then silently convert
        # into a pass. `tryEval` stays only so such an error surfaces as a
        # test failure rather than as an eval crash.
        result.success
        && builtins.any (a: lib.hasInfix "proxy.headers" a.message) failed
    );

    # A plain-string header on a proxied server is NOT a credential and must
    # keep working — the guard above has to reject secrets without rejecting
    # ordinary client config.
    module-mcp-proxy-literal-client-headers-allowed = mkTest "mcp-proxy-literal-client-headers-allowed" (
      let
        result = evalHm {
          ai.kiro = {
            enable = true;
            mcpServers.jira = {
              type = "http";
              url.file = "/run/secrets/jira-url";
              headers."X-Client-Sent" = "yes";
              proxy = {
                enable = true;
                port = 9501;
                headers."X-Jira-Token".file = "/run/secrets/service-token";
              };
            };
          };
        };
        failed = builtins.filter (a: !a.assertion) result.config.assertions;
      in
        builtins.all (a: !(lib.hasInfix "proxy.headers" a.message)) failed
    );

    # With no request headers in the logs, the UNIT is the only thing that
    # says which proxy a line came from. Without an explicit identifier the
    # visible one is the ExecStart store basename, whose hash changes on
    # every rebuild.
    module-mcp-proxy-unit-has-stable-syslog-identifier = mkTest "mcp-proxy-unit-has-stable-syslog-identifier" (
      let
        result = evalHm {
          ai.kiro = {
            enable = true;
            mcpServers.jira = {
              type = "http";
              url.file = "/run/secrets/jira-url";
              proxy = {
                enable = true;
                port = 9501;
                headers."X-Jira-Token".file = "/run/secrets/service-token";
              };
            };
          };
        };
        svc = result.config.systemd.user.services.mcp-proxy-jira.Service;
      in
        svc.SyslogIdentifier == "mcp-proxy-jira"
    );

    module-mcp-proxy-unit-isolates-caddy-state = mkTest "mcp-proxy-unit-isolates-caddy-state" (
      let
        result = evalHm {
          ai.kiro = {
            enable = true;
            mcpServers.jira = proxySampleServer;
          };
        };
        svc = result.config.systemd.user.services.mcp-proxy-jira.Service;
      in
        svc.RuntimeDirectory
        == "mcp-proxy-jira"
        && svc.RuntimeDirectoryMode == "0700"
        && svc.Environment
        == [
          "XDG_CONFIG_HOME=%t/mcp-proxy-jira/config"
          "XDG_DATA_HOME=%t/mcp-proxy-jira/data"
        ]
    );

    # Secrets must be read at RUNTIME from their files and never appear in
    # argv — /proc/<pid>/cmdline is world-readable. The environment is still
    # readable by same-uid processes, so this is not a process-isolation
    # boundary. Also pins the absolute-coreutils-path rule and fail-closed.
    module-mcp-proxy-start-script-reads-secrets-at-runtime = mkTest "mcp-proxy-start-script-reads-secrets-at-runtime" (
      let
        s = builtins.readFile (mcpProxyLib.startScriptFor (mcpProxyLib.specFor "example" proxySampleServer));
      in
        lib.hasInfix "/bin/cat \"/run/secrets/service-token\"" s
        && lib.hasInfix "export MCP_PROXY_EXAMPLE_X_SERVICE_TOKEN" s
        && lib.hasInfix "set -euETo pipefail" s
        && lib.hasInfix "shopt -s inherit_errexit" s
        # Fail closed: an empty or unreadable secret must not start a proxy
        # that would answer every client with the upstream's 401.
        && lib.hasInfix "resolved empty from" s
        && lib.hasInfix "the file is missing or unreadable" s
        # Never a bare `cat` — this wrapper can be spawned with no PATH.
        && !(lib.hasInfix "\ncat " s)
        # The secret must not be an ARGUMENT to caddy.
        && !(lib.hasInfix "--header" s)
    );

    # A credential-valued http header reaching the shared renderServer via a
    # non-Kiro path throws — non-Kiro ecosystems do not inject secret
    # headers (rather than serialize the raw file path). Forced via toJSON.
    module-mcp-credential-header-non-kiro-throws =
      mkTest "mcp-credential-header-non-kiro-throws" (!(builtins.tryEval (builtins.toJSON (mcpLib.renderServer pkgs "x" {
        type = "http";
        url = "u";
        headers.H.file = "/f";
      })))
    .success);

    # A credential-valued http URL reaching the shared renderServer via a
    # non-Kiro path throws (mirrors the header guard) — only Kiro assembles
    # a private mcp.json for a secret url.
    module-mcp-credential-url-non-kiro-throws =
      mkTest "mcp-credential-url-non-kiro-throws" (!(builtins.tryEval (builtins.toJSON (mcpLib.renderServer pkgs "x" {
        type = "http";
        url.file = "/f";
      })))
    .success);

    # The guard is the point of the change, so exercise it as SHELL rather
    # than as a grep: run a generated snippet against a genuinely empty file
    # and against a populated one. A grep proves the line was emitted; only
    # running it proves the line works.
    module-credential-empty-guard-aborts = let
      credLib = import ../../lib/credentials.nix {inherit lib;};
      # `mkSecretExport` bakes the path in at generation time and the test
      # needs two different files, so the path is a placeholder substituted
      # per-case below.
      runner = pkgs.writeShellScript "empty-guard-runner" ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        ${credLib.mkSecretExport pkgs "TEST_TOKEN" {file = "@SECRET@";}}
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

        empty=$(mktemp) && : > "$empty"
        full=$(mktemp) && printf 'a-real-token' > "$full"
        sed "s|@SECRET@|$full|"  ${runner} > full.sh
        sed "s|@SECRET@|$empty|" ${runner} > empty.sh

        # Positive control. Without it, a guard that rejected EVERYTHING would
        # still pass the negative case below and look correct.
        got=$(${pkgs.bash}/bin/bash full.sh 2>&1)
        [ "$got" = "REACHED-PROGRAM" ] || {
          echo "FAIL: populated secret was rejected (got: $got)" >&2
          exit 1
        }

        # A DIRECTORY must abort with the guard's own message. `-r` alone is
        # true for a readable directory, so without the `-d` branch this
        # sails past and dies on `cat: …: Is a directory`, losing the
        # variable name and the path the guard exists to report.
        mkdir -p secret-dir
        sed "s|@SECRET@|$PWD/secret-dir|" ${runner} > dir.sh
        if got=$(${pkgs.bash}/bin/bash dir.sh 2>&1); then
          echo "FAIL: a directory as the secret path did not abort (got: $got)" >&2
          exit 1
        fi
        case "$got" in
          *"is a directory, not a secret file"*) : ;;
          *)
            echo "FAIL: directory aborted, but not via the guard (got: $got)" >&2
            exit 1 ;;
        esac

        # The real case: an empty file must abort, non-zero, before the
        # program is reached.
        if got=$(${pkgs.bash}/bin/bash empty.sh 2>&1); then
          echo "FAIL: empty secret did not abort the wrapper (got: $got)" >&2
          exit 1
        fi
        case "$got" in
          *REACHED-PROGRAM*)
            echo "FAIL: reached the program despite the guard" >&2; exit 1 ;;
          *"TEST_TOKEN resolved empty"*) : ;;
          *)
            echo "FAIL: aborted, but not via the guard (got: $got)" >&2; exit 1 ;;
        esac

        echo PASS > "$out"
      '';
  };
}
