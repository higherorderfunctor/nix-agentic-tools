# Shared content generation logic for AI CLI modules.
#
# Consumed by:
# - packages/*/lib/mk*.nix (factory-built HM + devenv modules)
# - lib/hm-helpers.nix (filterNulls re-export)
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

  # ── Rule submodule type ────────────────────────────────────────────
  # Attrs-shaped analog of instructionModule. Each entry becomes one file
  # in the per-ecosystem rules directory (.claude/rules/<name>.md,
  # .kiro/steering/<name>.md, .github/instructions/<name>.instructions.md).
  # The attribute name becomes the filename stem. `text` accepts either
  # inline markdown lines or a path to a file.
  #
  # Graduated shape replacing the list-of-attrs `instructions` pattern —
  # attrs let per-CLI overrides win on name collision and produce
  # deterministic ordering. List shape is kept for back-compat; rules
  # and instructions coexist in the factory emission.
  ruleModule = lib.types.submodule {
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
          File path globs this rule applies to. null = always loaded.
          Translated per ecosystem:
          - Claude: paths: frontmatter
          - Kiro: inclusion: fileMatch + fileMatchPattern:
          - Copilot: applyTo: glob
        '';
      };
      text = lib.mkOption {
        type = lib.types.either lib.types.lines lib.types.path;
        description = "Rule body (inline markdown or path to a .md file).";
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

  # Flatten nested Nix attrsets into dot-notation keys for CLIs that
  # expect flat JSON (e.g., Kiro's cli.json uses `"chat.enableTangentMode"`
  # not `{"chat":{"enableTangentMode":...}}`). Supports grouping:
  #
  #   { mcp.loadedBefore = true; chat = { enableTangentMode = true; enableCheckpoint = true; }; }
  #   → { "mcp.loadedBefore" = true; "chat.enableTangentMode" = true; "chat.enableCheckpoint" = true; }
  #
  # Leaf values (non-attrset, or attrsets with `_type` like mkOption
  # results) are kept as-is. Only plain nested attrsets are flattened.
  flattenDotKeys = let
    go = prefix: attrs:
      lib.foldlAttrs (acc: name: value: let
        key =
          if prefix == ""
          then name
          else "${prefix}.${name}";
      in
        if lib.isAttrs value && !(value ? _type)
        then acc // (go key value)
        else acc // {${key} = value;})
      {}
      attrs;
  in
    go "";

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
