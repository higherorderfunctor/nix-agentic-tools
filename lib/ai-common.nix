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

  # ── Frontmatter generators ─────────────────────────────────────────

  # Generate Claude rules frontmatter
  mkClaudeRule = _name: instr: let
    descYaml =
      if instr.description != ""
      then "\ndescription: ${instr.description}"
      else "";
    pathsYaml =
      if instr.paths != null
      then "\npaths:\n${lib.concatMapStringsSep "\n" (p: "  - \"${p}\"") instr.paths}"
      else "";
    frontmatter =
      if pathsYaml != "" || descYaml != ""
      then "---${descYaml}${pathsYaml}\n---\n\n"
      else "";
  in
    frontmatter + instr.text;

  # Generate Kiro steering frontmatter
  mkKiroSteering = name: instr: let
    inclusion =
      if instr.paths != null
      then "fileMatch"
      else "always";
    descYaml =
      if instr.description != ""
      then "\ndescription: ${instr.description}"
      else "";
    patternYaml =
      if instr.paths != null
      then "\nfileMatchPattern: \"${lib.concatStringsSep "," instr.paths}\""
      else "";
  in ''
    ---
    name: ${name}${descYaml}
    inclusion: ${inclusion}${patternYaml}
    ---

    ${instr.text}
  '';

  # Generate Copilot instruction frontmatter
  mkCopilotInstruction = _name: instr: let
    applyTo =
      if instr.paths != null
      then lib.concatStringsSep "," instr.paths
      else "**";
  in ''
    ---
    applyTo: "${applyTo}"
    ---

    ${instr.text}
  '';

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
