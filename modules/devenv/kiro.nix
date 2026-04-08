# Kiro CLI devenv integration.
# Mirrors devenv's claude.nix pattern for Kiro's file layout.
#
# Generates:
#   .kiro/settings/mcp.json — MCP server config
#   .kiro/settings/cli.json — CLI settings (if configured)
#   .kiro/skills/{name} — skill directories (symlinked)
#   .kiro/steering/{name}.md — steering files
{
  pkgs,
  lib,
  config,
  ...
}: let
  cfg = config.kiro;
  jsonFormat = pkgs.formats.json {};
  helpers = import ../../lib/hm-helpers.nix {inherit lib;};
  mcpCommon = import ./mcp-common.nix {inherit lib;};

  filteredSettings = helpers.filterNulls cfg.settings;

  # Build MCP config
  mcpServers = lib.mapAttrs (_: mcpCommon.transformMcpServer) cfg.mcpServers;

  mcpContent =
    if cfg.mcpServers == {}
    then null
    else {inherit mcpServers;};
in {
  options.kiro = {
    enable = lib.mkEnableOption "Kiro CLI integration";

    agents = lib.mkOption {
      type = lib.types.attrsOf lib.types.lines;
      default = {};
      description = "Agent JSON definitions (written to .kiro/agents/{name}.json).";
    };

    environmentVariables = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Environment variables for Kiro (merged into devenv env).";
    };

    hooks = lib.mkOption {
      type = lib.types.attrsOf lib.types.lines;
      default = {};
      description = "Hook JSON definitions (written to .kiro/hooks/{name}.json).";
    };

    lspServers = lib.mkOption {
      type = lib.types.attrsOf jsonFormat.type;
      default = {};
      description = "LSP server definitions (written to .kiro/settings/lsp.json).";
    };

    mcpServers = lib.mkOption {
      type = mcpCommon.mcpServerType;
      default = {};
      description = "MCP servers to configure for Kiro.";
    };

    settings = lib.mkOption {
      type = lib.types.submodule {
        freeformType = jsonFormat.type;
        options = {
          chat = lib.mkOption {
            type = lib.types.submodule {
              freeformType = jsonFormat.type;
              options = {
                defaultModel = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "Default chat model.";
                };
                enableThinking = lib.mkOption {
                  type = lib.types.nullOr lib.types.bool;
                  default = null;
                  description = "Enable thinking/reasoning mode.";
                };
              };
            };
            default = {};
            description = "Chat-related settings.";
          };
          telemetry = lib.mkOption {
            type = lib.types.submodule {
              freeformType = jsonFormat.type;
              options = {
                enabled = lib.mkOption {
                  type = lib.types.nullOr lib.types.bool;
                  default = null;
                  description = "Enable telemetry reporting.";
                };
              };
            };
            default = {};
            description = "Telemetry settings.";
          };
        };
      };
      default = {};
      description = "Kiro CLI settings (written to .kiro/settings/cli.json).";
    };

    skills = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = {};
      description = "Skill directories to install for Kiro.";
    };

    steering = lib.mkOption {
      type = lib.types.attrsOf lib.types.lines;
      default = {};
      description = "Steering files for Kiro (.kiro/steering/).";
    };
  };

  config = lib.mkIf cfg.enable {
    env = lib.mapAttrs (_: lib.mkDefault) cfg.environmentVariables;

    files =
      # Agents
      lib.concatMapAttrs (name: content: {
        ".kiro/agents/${name}.json".text = content;
      })
      cfg.agents
      # Hooks
      // lib.concatMapAttrs (name: content: {
        ".kiro/hooks/${name}.json".text = content;
      })
      cfg.hooks
      # LSP servers
      // lib.optionalAttrs (cfg.lspServers != {}) {
        ".kiro/settings/lsp.json".json = cfg.lspServers;
      }
      # MCP servers
      // lib.optionalAttrs (mcpContent != null) {
        ".kiro/settings/mcp.json".json = mcpContent;
      }
      # Settings
      // lib.optionalAttrs (filteredSettings != {}) {
        ".kiro/settings/cli.json".json = filteredSettings;
      }
      # Skills (walked per-file for Layout B parity with HM)
      // helpers.mkDevenvSkillEntries ".kiro" cfg.skills
      # Steering
      // lib.concatMapAttrs (name: content: {
        ".kiro/steering/${name}.md".text = content;
      })
      cfg.steering;
  };
}
