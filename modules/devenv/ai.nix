# Unified AI configuration module for devenv.
#
# Single source of truth for shared config across Claude Code, Copilot,
# and Kiro in devenv context. Fans out to individual devenv modules via
# mkDefault so per-ecosystem config always wins.
#
# Pattern mirrors the home-manager modules/ai/default.nix but targets
# devenv's files.* instead of home.file.
#
# Usage:
#   ai = {
#     enable = true;
#     enableClaude = true;
#     enableCopilot = true;
#     enableKiro = true;
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
    types
    ;

  aiCommon = import ../../lib/ai-common.nix {inherit lib;};
  inherit (aiCommon) instructionModule lspServerModule mkClaudeRule mkCopilotInstruction mkCopilotLspConfig mkKiroSteering mkLspConfig;

  cfg = config.ai;

  # Check if an option path exists (returns true if defined, even if not set).
  hasOpt = path: lib.hasAttrByPath path config;
in {
  options.ai = {
    enable = mkEnableOption "unified AI configuration across Claude, Copilot, and Kiro";

    enableClaude = mkOption {
      type = types.bool;
      default = false;
      description = "Fan out shared config to claude.code and files.*.";
    };

    enableCopilot = mkOption {
      type = types.bool;
      default = false;
      description = "Fan out shared config to copilot.*.";
    };

    enableKiro = mkOption {
      type = types.bool;
      default = false;
      description = "Fan out shared config to kiro.*.";
    };

    environmentVariables = mkOption {
      type = types.attrsOf types.str;
      default = {};
      description = "Shared environment variables for all enabled CLIs.";
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
      '';
      example = lib.literalExpression ''
        {
          nixd = { package = pkgs.nixd; extensions = ["nix"]; };
          marksman = { package = pkgs.marksman; extensions = ["md"]; };
        }
      '';
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

    skills = mkOption {
      type = types.attrsOf types.path;
      default = {};
      description = ''
        Shared skills (directory paths). Identical format across ecosystems.
        Injected at mkDefault priority so per-ecosystem config wins.
      '';
    };
  };

  config = mkIf cfg.enable (mkMerge [
    # Shared environment variables — merge into devenv env for all ecosystems
    (mkIf (cfg.environmentVariables != {}) {
      env = lib.mapAttrs (_: mkDefault) cfg.environmentVariables;
    })

    # Claude Code — uses files.* for both rules and skills
    (mkIf cfg.enableClaude (mkMerge [
      {
        files =
          # Instructions as Claude rules with frontmatter
          concatMapAttrs (name: instr: {
            ".claude/rules/${name}.md".text = mkDefault (mkClaudeRule name instr);
          })
          cfg.instructions
          # Skills as directory symlinks
          // concatMapAttrs (name: path: {
            ".claude/skills/${name}".source = mkDefault path;
          })
          cfg.skills;
      }
      # Auto-set ENABLE_LSP_TOOL=1 when LSP servers are configured
      (mkIf (cfg.lspServers != {} && hasOpt ["claude" "code" "env"]) {
        claude.code.env.ENABLE_LSP_TOOL = mkDefault "1";
      })
      # Normalized model setting
      (mkIf (cfg.settings.model != null && hasOpt ["claude" "code" "model"]) {
        claude.code.model = mkDefault cfg.settings.model;
      })
    ]))

    # Copilot — uses copilot.* options
    (mkIf cfg.enableCopilot {
      copilot = {
        environmentVariables = lib.mapAttrs (_: mkDefault) cfg.environmentVariables;
        instructions = lib.mapAttrs (name: instr:
          mkDefault (mkCopilotInstruction name instr))
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

    # Kiro — uses kiro.* options
    (mkIf cfg.enableKiro {
      kiro = {
        environmentVariables = lib.mapAttrs (_: mkDefault) cfg.environmentVariables;
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
          mkDefault (mkKiroSteering name instr))
        cfg.instructions;
      };
    })
  ]);
}
