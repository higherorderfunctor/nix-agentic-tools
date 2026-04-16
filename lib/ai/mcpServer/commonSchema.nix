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
#   (C) External HTTP — for already-running services
#       { type = "http"; url = "..."; }
#       Pass-through. Used by services.mcp-servers outputs and
#       lib.externalServers.
{lib, ...}: {
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
      description = "HTTP endpoint URL. Required for shape (C).";
    };
  };
}
