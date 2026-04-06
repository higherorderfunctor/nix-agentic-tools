# Unified AI configuration module.
#
# Single source of truth for shared config across Claude Code, Copilot CLI,
# and Kiro CLI. Fans out to individual CLI modules via mkDefault so
# per-CLI config always wins.
#
# Usage:
#   ai = {
#     enable = true;
#     claude.enable = true;
#     copilot.enable = true;
#     kiro.enable = true;
#     skills = { stack-fix = ./skills/stack-fix; };
#     instructions.coding-standards = {
#       text = "Always use strict mode...";
#       paths = [ "src/**" ];
#       description = "Project coding standards";
#     };
#   };
{
  config,
  lib,
  options,
  pkgs,
  ...
}: let
  inherit
    (lib)
    attrByPath
    concatMapAttrs
    mkDefault
    mkEnableOption
    mkIf
    mkMerge
    mkOption
    types
    ;

  aiCommon = import ../../lib/ai-common.nix {inherit lib;};
  inherit (aiCommon) instructionModule lspServerModule mkCopilotLspConfig mkLspConfig;
  aiTransforms = pkgs.fragments-ai.passthru.transforms;

  cfg = config.ai;

  # Check if a module option path exists (use options, not config)
  hasModule = path:
    (attrByPath path null options) != null;
in {
  options.ai = {
    enable = mkEnableOption "unified AI configuration across Claude, Copilot, and Kiro";

    claude = mkOption {
      type = types.submodule {
        options = {
          enable = mkEnableOption "Fan out shared config to Claude Code";
          package = mkOption {
            type = types.package;
            default = pkgs.claude-code;
            description = "Claude Code package.";
          };
        };
      };
      default = {};
    };

    copilot = mkOption {
      type = types.submodule {
        options = {
          enable = mkEnableOption "Fan out shared config to Copilot CLI";
          package = mkOption {
            type = types.package;
            default = pkgs.github-copilot-cli;
            description = "Copilot CLI package.";
          };
        };
      };
      default = {};
    };

    kiro = mkOption {
      type = types.submodule {
        options = {
          enable = mkEnableOption "Fan out shared config to Kiro CLI";
          package = mkOption {
            type = types.package;
            default = pkgs.kiro-cli;
            description = "Kiro CLI package.";
          };
        };
      };
      default = {};
    };

    skills = mkOption {
      type = types.attrsOf types.path;
      default = {};
      description = ''
        Shared skills (directory paths). Identical format across ecosystems.
        Injected at mkDefault priority so per-CLI skills win.
      '';
    };

    instructions = mkOption {
      type = types.attrsOf instructionModule;
      default = {};
      description = ''
        Shared instructions with optional path scoping. Body is shared;
        frontmatter is generated per ecosystem.
      '';
    };

    lspServers = mkOption {
      type = types.attrsOf lspServerModule;
      default = {};
      description = ''
        Typed LSP server definitions with explicit packages. Transformed
        to per-ecosystem JSON (with full store paths) during fanout.
        Each CLI writes the result to its own config path.
      '';
      example = lib.literalExpression ''
        {
          nixd = { package = pkgs.nixd; extensions = ["nix"]; };
          marksman = { package = pkgs.marksman; extensions = ["md"]; };
        }
      '';
    };

    environmentVariables = mkOption {
      type = types.attrsOf types.str;
      default = {};
      description = "Shared environment variables for all enabled CLIs.";
    };

    settings = mkOption {
      type = types.submodule {
        options = {
          model = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Default model -- translated per ecosystem.";
          };
          telemetry = mkOption {
            type = types.nullOr types.bool;
            default = null;
            description = "Enable/disable telemetry -- translated per ecosystem.";
          };
        };
      };
      default = {};
      description = "Normalized settings translated to ecosystem-specific keys.";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    # Assertions
    {
      assertions = [
        # Claude Code uses home.file directly, no upstream module dependency.
        # If programs.claude-code IS available, users can still configure it
        # directly for Claude-specific settings (model, permissions, etc.).
        {
          assertion = cfg.copilot.enable -> hasModule ["programs" "copilot-cli" "enable"];
          message = "ai.copilot.enable requires programs.copilot-cli to be available.";
        }
        {
          assertion = cfg.kiro.enable -> hasModule ["programs" "kiro-cli" "enable"];
          message = "ai.kiro.enable requires programs.kiro-cli to be available.";
        }
        {
          assertion =
            cfg.skills
            != {}
            || cfg.instructions != {}
            || cfg.environmentVariables != {}
            -> cfg.claude.enable || cfg.copilot.enable || cfg.kiro.enable;
          message = "ai has shared config but no CLIs enabled. Set at least one of claude.enable, copilot.enable, kiro.enable.";
        }
      ];
    }

    # MCP bridging: ai doesn't have its own mcpServers option.
    # Users configure programs.mcp.servers directly and each CLI's
    # enableMcpIntegration picks them up. This avoids double-injection.

    # Claude Code — uses home.file for both rules and skills to avoid
    # depending on the upstream programs.claude-code module being imported.
    (mkIf cfg.claude.enable (mkMerge [
      {
        home.file =
          # Instructions as Claude rules with frontmatter
          (concatMapAttrs (name: instr: {
              ".claude/rules/${name}.md" = {
                text = mkDefault (aiTransforms.claude {package = name;} instr);
              };
            })
            cfg.instructions)
          # Skills as directory symlinks
          // (concatMapAttrs (name: path: {
              ".claude/skills/${name}" = {
                source = mkDefault path;
              };
            })
            cfg.skills);
      }
      # Auto-set ENABLE_LSP_TOOL=1 when LSP servers are configured
      (mkIf (cfg.lspServers != {} && hasModule ["programs" "claude-code" "settings"]) {
        programs.claude-code.settings.env.ENABLE_LSP_TOOL = mkDefault "1";
      })
      # Normalized model setting (only if upstream module is available)
      (mkIf (cfg.settings.model != null && hasModule ["programs" "claude-code" "settings"]) {
        programs.claude-code.settings.model = mkDefault cfg.settings.model;
      })
    ]))

    # Copilot CLI
    (mkIf cfg.copilot.enable {
      programs.copilot-cli = {
        environmentVariables =
          lib.mapAttrs (_: mkDefault) cfg.environmentVariables;
        instructions = lib.mapAttrs (_name: instr:
          mkDefault (aiTransforms.copilot instr))
        cfg.instructions;
        lspServers = lib.mapAttrs (name: server:
          mkDefault (mkCopilotLspConfig name server))
        cfg.lspServers;
        settings = lib.optionalAttrs (cfg.settings.model != null) {
          model = mkDefault cfg.settings.model;
        };
        skills = lib.mapAttrs (_: mkDefault) cfg.skills;
      };
    })

    # Kiro CLI
    (mkIf cfg.kiro.enable {
      programs.kiro-cli = {
        environmentVariables =
          lib.mapAttrs (_: mkDefault) cfg.environmentVariables;
        lspServers = lib.mapAttrs (name: server:
          mkDefault (mkLspConfig name server))
        cfg.lspServers;
        settings = mkMerge [
          (lib.optionalAttrs (cfg.settings.model != null) {
            chat.defaultModel = mkDefault cfg.settings.model;
          })
          (lib.optionalAttrs (cfg.settings.telemetry != null) {
            telemetry.enabled = mkDefault cfg.settings.telemetry;
          })
        ];
        skills = lib.mapAttrs (_: mkDefault) cfg.skills;
        steering = lib.mapAttrs (name: instr:
          mkDefault (aiTransforms.kiro {inherit name;} instr))
        cfg.instructions;
      };
    })
  ]);
}
