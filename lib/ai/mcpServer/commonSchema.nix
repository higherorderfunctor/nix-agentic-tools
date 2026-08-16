# Common typed shape for MCP server entries declared at
# `ai.mcpServers.<name>` and `ai.<ecosystem>.mcpServers.<name>`.
#
# Three supported shapes (discriminated by which fields are set):
#
#   (A) Typed-via-package — most servers
#       { package = <drv>; settings = {...}; env = {...}; args = [...]; }
#       Requires a server module at packages/<name>/modules/mcp-server.nix
#       (provides typed settings schema, mode strings, credentialVars).
#       Each ecosystem's renderServer translates to its native target,
#       wrapping the package with a credentials snippet when settings.*
#       includes file/helper credentials.
#
#   (B) Raw command — escape hatch for ad-hoc wrappers
#       { type = "stdio"; command = "<abs-path>"; args = [...]; env = {...}; }
#       Pass-through. Useful when the user hand-rolls a wrapper script
#       that doesn't need the server-module machinery (no credential
#       injection, no settings translation).
#
#   (C) External HTTP — for already-running / remote services
#       { type = "http"; url = "..."; headers = {...}; timeout = <ms>; }
#       Pass-through. Each `headers.<name>` value AND `url` may be a
#       plain string (baked into the store) OR a { file | helper;
#       prefix?; suffix?; var?; } SOPS/agenix credential. A credential
#       HEADER renders as a `${env:VAR}` placeholder the Kiro launcher
#       substitutes at runtime. A credential URL cannot use that path
#       (Kiro does not env-substitute the url field, verified against
#       2.13.0), so the launcher instead assembles it into a real,
#       private `mcp.json` at activation from the decrypted secret (see
#       `ai.kiro.mcpWriteMode`). Both are delivered for Kiro only; other
#       ecosystems throw on a credential value. See secretValue.nix.
#       Used by services.mcp-servers outputs and lib.ai.externalServers.
{lib, ...}: let
  secretValue = import ./secretValue.nix lib;
in {
  options = {
    type = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [
        "http"
        "stdio"
      ]);
      default = null;
      description = ''
        Transport type. Inferred from other fields when null:
        `url` set → http, `package` set → stdio, `command` set → stdio.
      '';
    };
    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = ''
        MCP server package (derivation). Required for shape (A).
        Null for raw command (B) and external HTTP (C).
      '';
    };
    command = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Absolute command path. Set this for shape (B) — raw
        pass-through, no wrapping. Leave null for shape (A) where the
        renderer derives the command from the package.
      '';
    };
    codex = lib.mkOption {
      type = lib.types.submodule {
        freeformType = lib.types.attrsOf lib.types.toml;
        options = {
          auth = lib.mkOption {
            type = lib.types.nullOr (lib.types.enum ["chatgpt" "oauth"]);
            default = null;
            description = "Codex authentication mode for this MCP server.";
          };
          bearerTokenEnvVar = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Environment variable containing an HTTP bearer token; the token itself is never rendered.";
          };
          cwd = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Working directory used when Codex starts a stdio MCP server.";
          };
          defaultToolsApprovalMode = lib.mkOption {
            type = lib.types.nullOr (lib.types.enum ["approve" "auto" "prompt" "writes"]);
            default = null;
            description = "Default Codex approval policy for tools not listed under `tools`.";
          };
          disabledTools = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "MCP tool names Codex must not expose from this server.";
          };
          enabled = lib.mkOption {
            type = lib.types.nullOr lib.types.bool;
            default = null;
            description = "Whether Codex enables this MCP server.";
          };
          enabledTools = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "Allowlist of MCP tool names Codex exposes from this server.";
          };
          envHttpHeaders = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = {};
            description = "HTTP header names mapped to environment-variable names; secret values stay out of the Nix store.";
          };
          envVars = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "Environment-variable names made available to the MCP server; values are never rendered.";
          };
          experimentalEnvironment = lib.mkOption {
            type = lib.types.nullOr (lib.types.enum ["local" "remote"]);
            default = null;
            description = "Experimental Codex execution environment for this MCP server.";
          };
          httpHeaders = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = {};
            description = "Non-secret literal HTTP headers. These values are written to the Nix store; use envHttpHeaders for secrets.";
          };
          oauthResource = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "OAuth resource identifier Codex sends during MCP authorization.";
          };
          required = lib.mkOption {
            type = lib.types.nullOr lib.types.bool;
            default = null;
            description = "Whether Codex treats failure to initialize this MCP server as fatal.";
          };
          scopes = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "OAuth scopes Codex requests for this MCP server.";
          };
          startupTimeoutSec = lib.mkOption {
            type = lib.types.nullOr lib.types.number;
            default = null;
            description = "Maximum seconds Codex waits for this MCP server to initialize.";
          };
          toolTimeoutSec = lib.mkOption {
            type = lib.types.nullOr lib.types.number;
            default = null;
            description = "Default maximum seconds Codex allows each tool call to run.";
          };
          tools = lib.mkOption {
            type = lib.types.attrsOf (lib.types.submodule {
              options.approvalMode = lib.mkOption {
                type = lib.types.enum ["approve" "auto" "prompt" "writes"];
                description = "Codex approval policy override for this MCP tool.";
              };
            });
            default = {};
            description = "Per-tool Codex approval policy overrides keyed by MCP tool name.";
          };
        };
      };
      default = {};
      description = "Codex-native MCP authentication, readiness, timeout, and tool-policy extensions. Unknown TOML-compatible keys are accepted.";
    };
    args = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Arguments passed to the server binary.";
    };
    env = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Environment variables for the server process.";
    };
    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
      description = ''
        Server-specific settings — typed by the server module's
        settingsOptions. Credentials (file/helper) flow through here
        and the renderer materializes them into a wrapper script.
      '';
    };
    url = lib.mkOption {
      type = lib.types.nullOr secretValue;
      default = null;
      description = ''
        HTTP endpoint URL for shape (C). A plain string (baked into the
        world-readable store) OR a { file | helper; prefix?; suffix?;
        var?; } SOPS/agenix credential. Kiro does NOT env-substitute the
        url field, so a credential url is not injected as a
        `''${env:VAR}` placeholder at launch like a header — instead the
        Kiro launcher assembles it into a real, private `mcp.json` at
        activation from the decrypted secret (see `ai.kiro.mcpWriteMode`).
        Delivered for Kiro only; other ecosystems throw on a credential
        url. See secretValue.nix.
      '';
    };
    headers = lib.mkOption {
      type = lib.types.attrsOf secretValue;
      default = {};
      description = ''
        HTTP request headers for shape (C). Each value is a plain string
        or a { file | helper; prefix?; suffix?; var?; } SOPS/agenix
        credential rendered as a `''${env:VAR}` placeholder — the Kiro
        launcher injects the secret into its environment at start
        (delivered for Kiro only; other ecosystems throw on a credential
        value).

        LIMITATION — a credential header authenticates only the kiro
        launcher that CARRIES it. The server list and these placeholders
        live in the user-global mcp.json, but the values are exported by
        the wrapped package, so any OTHER kiro on PATH reads the same
        servers and connects with NO credentials, silently. The common
        case is a devenv project that enables Kiro: it puts a second
        wrapped kiro on PATH which shadows the Home Manager one inside
        that shell, carrying secrets only for servers that project
        declares. Declare the same servers and secrets in the project, or
        prefer a `services.mcp-servers` daemon, which holds credentials
        itself and hands clients a credential-free loopback url. Full
        write-up: `dev/fragments/mcp-secrets/mcp-secrets.md` in the
        nix-agentic-tools repository.
      '';
    };
    proxy = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              Route this remote http server through a LOCAL
              credential-injecting reverse proxy instead of handing the
              credentials to the client.

              `url` and credential values under `proxy.headers` move into
              the proxy daemon's ENVIRONMENT, read from their secret files
              when the daemon starts. Top-level `headers` remain client
              headers and must be credential-free. The client receives a
              credential-free `http://<host>:<port>/` entry, so it no longer
              matters which binary launches it — the per-binary scope
              mismatch that affects `''${env:VAR}` header placeholders cannot
              apply, because the client holds no credential to get wrong.

              The MCP server attribute key is also the managed-proxy ownership
              key. A used top-level declaration owns one shared proxy and fans
              out only its lowered client entry. A runtime-scoped declaration
              owns its proxy directly. Reusing a proxy key across declaration
              scopes is an error; give direct owners different server keys.
              A top-level proxy inherited by no enabled runtime is not
              materialized.

              This also makes the server harness-agnostic. A credential
              header or url is Kiro-only (`renderServer` throws for other
              ecosystems rather than serialize a secret's path); the
              proxied entry carries neither, so Claude Code and Copilot
              can use it too.

              SCOPE — Home Manager on Linux only today. devenv parity and
              Darwin (launchd) are deliberately OUT OF SCOPE for this
              change and are explicitly NOT decided against — this is a
              deferral, not a WONTFIX. See
              `dev/fragments/mcp-secrets/mcp-secrets.md`. The devenv
              transform throws rather than silently ignoring the option.
            '';
          };
          host = lib.mkOption {
            type = lib.types.str;
            default = "127.0.0.1";
            description = ''
              Address the proxy listens on. Emitted as the Caddy `bind`
              directive — NOT as the site address, which would be a
              Host-header matcher and would leave the listener on every
              interface — and used as the host in the url handed to
              clients.

              The endpoint is UNAUTHENTICATED by design — that is what
              makes it independent of which binary connects. Two
              consequences worth being explicit about:

              - Binding a routable address publishes the use of the
                upstream credential to that whole network. Anyone who can
                reach the port can make authenticated requests.
              - Even on loopback it is reachable by ANY LOCAL USER, not
                just by you. On a multi-user machine that is a real
                boundary: local users cannot read the secret (it is only
                in the daemon's 0400 environ) but they CAN use it through
                this port.
            '';
          };
          port = lib.mkOption {
            type = lib.types.port;
            description = ''
              Port the proxy listens on. REQUIRED and explicit on
              purpose — a port derived from the server name would collide
              silently between two servers sharing a loopback address,
              and a silent loopback collision is a bad failure mode.
            '';
          };
          headers = lib.mkOption {
            type = lib.types.attrsOf (lib.types.nullOr secretValue);
            default = {};
            description = ''
              Headers the PROXY DAEMON applies on the way upstream. Three
              value shapes:

              - a credential (`{ file | helper; prefix?; suffix?; var?; }`)
                — read from its `file`, or produced by its `helper`, when
                the daemon starts.

                The SECRET VALUE never reaches the client, the Nix store,
                argv, or the journal. What lands in the store-backed
                Caddyfile is a `{$VAR}` PLACEHOLDER, wrapped in any
                `prefix`/`suffix`, which Caddy substitutes from the
                daemon's environment while parsing its config. The
                distinction matters: the rendered header line is public,
                the value it resolves to is not.
              - a plain string — injected literally.
              - `null` — DELETED, so a header the client sent does not
                reach the upstream.

              This is separate from the server's top-level `headers` on
              purpose, and the split is the whole interface: top-level
              `headers` are what the CLIENT sends, these are what the
              PROXY injects. Before 2026-08-13 the top-level ones were
              absorbed into the daemon whenever `proxy.enable` was set, so
              a single key meant two different things depending on a
              sibling flag.

              A credential in the server's top-level `headers` on a
              proxied server is an ERROR rather than an absorption — it
              would be handed to the client, which is exactly what the
              proxy exists to prevent.

              NOTE the daemon is shared: it is an unauthenticated loopback
              endpoint, so anything injected here is applied to every
              local client that reaches the port, not just the one you had
              in mind.
            '';
          };
        };
      });
      default = null;
      description = ''
        Local credential-injecting reverse proxy for a remote http server
        (shape C). Null (the default) disables it and the credentials are
        delivered to the client instead.
      '';
    };
    timeout = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      description = "Request timeout in milliseconds for shape (C) http servers.";
    };
  };
}
