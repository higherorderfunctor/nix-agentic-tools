# Shared content generation logic for AI CLI modules.
#
# Consumed by:
# - modules/ai/default.nix (HM unified AI config)
# - modules/devenv/ai.nix (devenv unified AI config)
# - modules/devenv/mcp-common.nix (devenv MCP server transform)
# - lib/hm-helpers.nix (filterNulls re-export)
# - modules/devenv/copilot.nix (filterNulls via hm-helpers)
# - modules/devenv/kiro.nix (filterNulls via hm-helpers)
{lib}: {
  # ── LSP server submodule type ──────────────────────────────────────
  # Typed LSP server definition. The ai.* module holds these; fanout
  # transforms to per-ecosystem JSON via mkLspConfig / mkCopilotLspConfig.
  lspServerModule = lib.types.submodule ({name, ...}: {
    options = {
      args = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = ["--stdio"];
        description = "Arguments to pass to the LSP binary.";
      };
      binary = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "Binary name within the package (defaults to the attribute name).";
      };
      extensions = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = "File extensions this server handles (without leading dots).";
        example = ["nix"];
      };
      initializationOptions = lib.mkOption {
        type = lib.types.attrs;
        default = {};
        description = "LSP initialization options passed during handshake.";
      };
      package = lib.mkOption {
        type = lib.types.package;
        description = "The LSP server package.";
      };
    };
  });

  # ── LSP config transforms ─────────────────────────────────────────
  # Transform a typed LSP server to the JSON format expected by CLIs.
  # Base format (Kiro): { command, args, ?initializationOptions }
  mkLspConfig = _name: server:
    {
      command = "${server.package}/bin/${server.binary}";
      inherit (server) args;
    }
    // lib.optionalAttrs (server.initializationOptions != {}) {
      inherit (server) initializationOptions;
    };

  # Copilot adds fileExtensions mapping: { ".ext" = "serverName"; }
  mkCopilotLspConfig = name: server:
    {
      command = "${server.package}/bin/${server.binary}";
      inherit (server) args;
    }
    // lib.optionalAttrs (server.extensions != []) {
      fileExtensions = lib.listToAttrs (map (ext: {
          name = ".${ext}";
          value = name;
        })
        server.extensions);
    }
    // lib.optionalAttrs (server.initializationOptions != {}) {
      inherit (server) initializationOptions;
    };

  # ── Instruction submodule type ──────────────────────────────────────
  # Shared semantic fields, translated per ecosystem by frontmatter generators.
  instructionModule = lib.types.submodule {
    options = {
      description = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Short description (used by Claude and Kiro frontmatter).";
      };
      paths = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.str);
        default = null;
        description = ''
          File path globs this instruction applies to. null = always loaded.
          Translated per ecosystem:
          - Claude: paths: frontmatter
          - Kiro: inclusion: fileMatch + fileMatchPattern:
          - Copilot: applyTo: glob
        '';
      };
      text = lib.mkOption {
        type = lib.types.lines;
        description = "Instruction body (markdown).";
      };
    };
  };

  # ── MCP server transform ───────────────────────────────────────────
  # Transform a typed MCP server submodule value into the JSON structure
  # expected by target ecosystems (VS Code mcp.json / Kiro mcp.json).
  transformMcpServer = server:
    if server.type == "stdio"
    then
      {
        type = "stdio";
        inherit (server) command;
      }
      // lib.optionalAttrs (server.args != []) {inherit (server) args;}
      // lib.optionalAttrs (server.env != {}) {inherit (server) env;}
    else if server.type == "http"
    then {
      type = "http";
      inherit (server) url;
    }
    else throw "Invalid MCP server type: ${server.type}";

  # ── Settings utilities ──────────────────────────────────────────────
  # Recursively filter null values from an attrset (for typed settings
  # with freeformType where defaults are null). Also removes empty
  # sub-attrsets left after filtering.
  filterNulls = let
    go = attrs: let
      mapped = lib.mapAttrs (_: v:
        if lib.isAttrs v
        then go v
        else v)
      attrs;
    in
      lib.filterAttrs (_: v: v != null && v != {}) mapped;
  in
    go;
}
