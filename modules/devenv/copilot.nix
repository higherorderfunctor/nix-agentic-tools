# GitHub Copilot devenv integration.
# Mirrors devenv's claude.nix pattern for Copilot's file layout.
#
# Generates:
#   .github/copilot-instructions.md — repo-wide instructions (via files.*)
#   .github/instructions/*.instructions.md — per-package scoped instructions
#   .github/skills/{name} — skill directories (symlinked)
#   .copilot/agents/{name}.md — agent files
#   .copilot/config.json — settings
#   .copilot/mcp.json — MCP server config
{
  pkgs,
  lib,
  config,
  ...
}: let
  cfg = config.copilot;
  jsonFormat = pkgs.formats.json {};
  helpers = import ../../lib/hm-helpers.nix {inherit lib;};
  mcpCommon = import ./mcp-common.nix {inherit lib;};

  filteredSettings = helpers.filterNulls cfg.settings;
in {
  options.copilot = {
    enable = lib.mkEnableOption "GitHub Copilot integration";

    agents = lib.mkOption {
      type = lib.types.attrsOf lib.types.lines;
      default = {};
      description = "Agent .md files (written to .copilot/agents/{name}.md).";
    };

    instructions = lib.mkOption {
      type = lib.types.attrsOf lib.types.lines;
      default = {};
      description = "Instruction files for Copilot (.github/instructions/).";
    };

    environmentVariables = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Environment variables for Copilot (merged into devenv env).";
    };

    lspServers = lib.mkOption {
      type = lib.types.attrsOf jsonFormat.type;
      default = {};
      description = "LSP server definitions (written to .copilot/lsp-config.json).";
    };

    mcpServers = lib.mkOption {
      type = mcpCommon.mcpServerType;
      default = {};
      description = "MCP servers to configure for Copilot.";
    };

    settings = lib.mkOption {
      type = lib.types.submodule {
        freeformType = jsonFormat.type;
        options = {
          model = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Default model for Copilot.";
          };
          theme = lib.mkOption {
            type = lib.types.nullOr (lib.types.enum ["dark" "light" "auto"]);
            default = null;
            description = "Color theme.";
          };
        };
      };
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
    env = lib.mapAttrs (_: lib.mkDefault) cfg.environmentVariables;

    files = let
      mcpServers = lib.mapAttrs (_: mcpCommon.transformMcpServer) cfg.mcpServers;
    in
      # Agents
      lib.concatMapAttrs (name: content: {
        ".copilot/agents/${name}.md".text = content;
      })
      cfg.agents
      # Instructions
      // lib.concatMapAttrs (name: content: {
        ".github/instructions/${name}.instructions.md".text = content;
      })
      cfg.instructions
      # LSP servers
      // lib.optionalAttrs (cfg.lspServers != {}) {
        ".copilot/lsp-config.json".json = cfg.lspServers;
      }
      # MCP servers
      // lib.optionalAttrs (cfg.mcpServers != {}) {
        ".copilot/mcp.json".json = {inherit mcpServers;};
      }
      # Settings
      // lib.optionalAttrs (filteredSettings != {}) {
        ".copilot/config.json".json = filteredSettings;
      }
      # Skills (walked per-file for Layout B parity with HM)
      // helpers.mkDevenvSkillEntries ".github" cfg.skills;
  };
}
