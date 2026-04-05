# GitHub Copilot devenv integration.
# Mirrors devenv's claude.nix pattern for Copilot's file layout.
#
# Generates:
#   .github/copilot-instructions.md — repo-wide instructions (via files.*)
#   .github/instructions/*.instructions.md — per-package scoped instructions
#   .github/skills/{name} — skill directories (symlinked)
#   .vscode/mcp.json — MCP server config
#   .copilot/config.json — settings
{
  pkgs,
  lib,
  config,
  ...
}: let
  cfg = config.copilot;
  mcpCommon = import ./mcp-common.nix {inherit lib;};
in {
  options.copilot = {
    enable = lib.mkEnableOption "GitHub Copilot integration";

    instructions = lib.mkOption {
      type = lib.types.attrsOf lib.types.lines;
      default = {};
      description = "Instruction files for Copilot (.github/instructions/).";
    };

    # TODO: lspServers — unclear what format Copilot uses in devenv context.
    # Placeholder option; config block does not generate files yet.
    lspServers = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "LSP server config (written to .vscode/settings.json or similar).";
    };

    mcpServers = lib.mkOption {
      type = mcpCommon.mcpServerType;
      default = {};
      description = "MCP servers to configure for Copilot.";
    };

    settings = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = "Copilot settings (written to .copilot/config.json).";
    };

    skills = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = {};
      description = "Skill directories to install for Copilot.";
    };
  };

  config = lib.mkIf cfg.enable {
    files = let
      mcpServers = lib.mapAttrs (_: mcpCommon.transformMcpServer) cfg.mcpServers;
    in
      # MCP servers
      lib.optionalAttrs (cfg.mcpServers != {}) {
        ".vscode/mcp.json".json = {inherit mcpServers;};
      }
      # Settings
      // lib.optionalAttrs (cfg.settings != {}) {
        ".copilot/config.json".json = cfg.settings;
      }
      # Skills (directory symlinks)
      // lib.concatMapAttrs (name: path: {
        ".github/skills/${name}".source = path;
      })
      cfg.skills
      # Instructions
      // lib.concatMapAttrs (name: content: {
        ".github/instructions/${name}.instructions.md".text = content;
      })
      cfg.instructions;
  };
}
