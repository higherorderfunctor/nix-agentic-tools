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
#       Pass-through. Each `headers.<name>` value may be a plain string
#       (baked into the store) OR a { file | helper; prefix?; suffix?;
#       var?; } SOPS/agenix credential rendered as a `${env:VAR}`
#       placeholder (the Kiro launcher injects the secret at runtime;
#       delivered for Kiro only, other ecosystems throw). `url` is a
#       plain string — Kiro does not env-substitute the url field
#       (verified against 2.13.0), so a secret url would need the
#       proxy-bridge approach, not native injection. See secretValue.nix.
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
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        HTTP endpoint URL. Required for shape (C). Plain string only —
        Kiro does not env-substitute the url field, so a secret url is
        not supported via native injection (use a plain URL in your own
        private config, or the proxy-bridge approach to keep it out of
        the store).
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
      '';
    };
    timeout = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      description = "Request timeout in milliseconds for shape (C) http servers.";
    };
  };
}
