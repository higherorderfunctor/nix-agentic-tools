# Unified AI configuration module.
#
# Single source of truth for shared config across Claude Code, Copilot CLI,
# and Kiro CLI. Fans out to individual CLI modules via mkDefault so
# per-CLI config always wins.
#
# Each ai.{claude,copilot,kiro}.enable is the SOLE gate for that CLI's
# fanout — it also implicitly enables the corresponding upstream module
# (programs.claude-code.enable, programs.copilot-cli.enable, etc.), so
# consumers don't need to set enable twice. There is no master ai.enable
# switch; enabling at least one ecosystem sub-option is the activation.
#
# Usage:
#   ai = {
#     claude.enable = true;   # also sets programs.claude-code.enable
#     copilot.enable = true;  # also sets programs.copilot-cli.enable
#     kiro.enable = true;     # also sets programs.kiro-cli.enable
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
  pkgs,
  ...
}: let
  inherit
    (lib)
    concatMapAttrs
    mkDefault
    mkEnableOption
    mkIf
    mkMerge
    mkOption
    optionals
    types
    ;

  aiCommon = import ../../lib/ai-common.nix {inherit lib;};
  aiOptions = import ../../lib/ai-options.nix {inherit lib;};
  inherit (aiCommon) mkCopilotLspConfig mkLspConfig;
  aiTransforms = pkgs.fragments-ai.passthru.transforms;

  inherit (import ../../lib/buddy-types.nix {inherit lib;}) buddySubmodule;

  cfg = config.ai;
in {
  # Pull in the HM modules this one references inside its mkIf
  # blocks. Without these imports, consumers importing only
  # `homeManagerModules.ai` get eval errors like
  # "programs.copilot-cli.enable is not a declared option"
  # because NixOS modules need option paths declared even when
  # the mkIf guard is false.
  imports = [
    ../claude-code-buddy
    ../copilot-cli
    ../kiro-cli
  ];

  options.ai = {
    claude = mkOption {
      type = types.submodule {
        options = {
          enable = mkEnableOption "Fan out shared config to Claude Code";
          package = mkOption {
            type = types.package;
            default = pkgs.claude-code;
            defaultText = lib.literalExpression "pkgs.claude-code";
            description = "Claude Code package.";
          };
          buddy = mkOption {
            type = types.nullOr buddySubmodule;
            default = null;
            description = ''
              Buddy companion customization. When set, fans out to
              `programs.claude-code.buddy` which installs an
              activation script to patch the buddy salt at activation
              time. See modules/claude-code-buddy/ for details.
            '';
          };
        };
      };
      default = {};
      description = "Claude Code ecosystem configuration.";
    };

    copilot = mkOption {
      type = types.submodule {
        options = {
          enable = mkEnableOption "Fan out shared config to Copilot CLI";
          package = mkOption {
            type = types.package;
            default = pkgs.github-copilot-cli;
            defaultText = lib.literalExpression "pkgs.github-copilot-cli";
            description = "Copilot CLI package.";
          };
        };
      };
      default = {};
      description = "Copilot CLI ecosystem configuration.";
    };

    kiro = mkOption {
      type = types.submodule {
        options = {
          enable = mkEnableOption "Fan out shared config to Kiro CLI";
          package = mkOption {
            type = types.package;
            default = pkgs.kiro-cli;
            defaultText = lib.literalExpression "pkgs.kiro-cli";
            description = "Kiro CLI package.";
          };
        };
      };
      default = {};
      description = "Kiro CLI ecosystem configuration.";
    };

    skills = aiOptions.skillsOption;

    instructions = aiOptions.instructionsOption;

    lspServers = aiOptions.lspServersOption;

    environmentVariables = aiOptions.environmentVariablesOption;

    settings = aiOptions.settingsOption;
  };

  config = mkMerge [
    # Assertions — per-CLI enables are the only gates; always-on so
    # misconfigurations surface even when nothing else is set.
    {
      assertions =
        [
          {
            assertion =
              cfg.skills
              != {}
              || cfg.instructions != {}
              || cfg.environmentVariables != {}
              -> cfg.claude.enable || cfg.copilot.enable || cfg.kiro.enable;
            message = "ai has shared config but no CLIs enabled. Set at least one of claude.enable, copilot.enable, kiro.enable.";
          }
        ]
        ++ (optionals (cfg.claude.buddy != null) [
          {
            assertion = cfg.claude.buddy.peak != cfg.claude.buddy.dump || cfg.claude.buddy.peak == null;
            message = "ai.claude.buddy: peak and dump stats must differ";
          }
          {
            assertion = cfg.claude.buddy.rarity == "common" -> cfg.claude.buddy.hat == "none";
            message = "ai.claude.buddy: common rarity forces hat = \"none\"";
          }
        ]);
    }

    # MCP bridging: ai doesn't have its own mcpServers option.
    # Users configure programs.mcp.servers directly and each CLI's
    # enableMcpIntegration picks them up. This avoids double-injection.

    # Claude Code — ai.claude.enable is the sole gate. It also flips
    # programs.claude-code.enable so consumers don't set enable twice.
    (mkIf cfg.claude.enable (mkMerge [
      {
        programs.claude-code.enable = mkDefault true;
        programs.claude-code.skills = lib.mapAttrs (_: mkDefault) cfg.skills;
        home.file =
          # Instructions as Claude rules with frontmatter
          concatMapAttrs (name: instr: {
            ".claude/rules/${name}.md" = {
              text = mkDefault (aiTransforms.claude {package = name;} instr);
            };
          })
          cfg.instructions;
      }
      # Auto-set ENABLE_LSP_TOOL=1 when LSP servers are configured
      (mkIf (cfg.lspServers != {}) {
        programs.claude-code.settings.env.ENABLE_LSP_TOOL = mkDefault "1";
      })
      # Normalized model setting
      (mkIf (cfg.settings.model != null) {
        programs.claude-code.settings.model = mkDefault cfg.settings.model;
      })
      # Buddy fanout — sets the canonical programs.claude-code.buddy
      (mkIf (cfg.claude.buddy != null) {
        programs.claude-code.buddy = cfg.claude.buddy;
      })
    ]))

    # Copilot CLI — ai.copilot.enable also flips programs.copilot-cli.enable.
    (mkIf cfg.copilot.enable {
      programs.copilot-cli = {
        enable = mkDefault true;
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

    # Kiro CLI — ai.kiro.enable also flips programs.kiro-cli.enable.
    (mkIf cfg.kiro.enable {
      programs.kiro-cli = {
        enable = mkDefault true;
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
  ];
}
