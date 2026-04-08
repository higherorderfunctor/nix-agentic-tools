# ============================================================================
# REFERENCE ONLY — PRE-FACTORY FANOUT PATTERN.
#
# This file is NOT imported by any flake output. It is kept in the tree
# solely as source material for the `ai.*` fanout absorption work tracked
# in `docs/plan.md` "Ideal architecture gate → Absorption backlog".
#
# Do NOT import this into `homeManagerModules.nix-agentic-tools`. The
# factory path for the same behavior is
# `lib.ai.app.mkAiApp` + `packages/<name>/lib/mk<Name>.nix`, wired into
# the module barrel via `flake.nix:collectFacet ["modules" "homeManager"]`.
#
# Known stale references in this file:
# - `pkgs.fragments-ai.passthru.transforms` — package dissolved in M9;
#   the equivalent live surface is `lib/ai/transformers/*.nix` consumed
#   via `fragmentsLib.mkRenderer <transformer> <ctxExtras>`.
# - `programs.{claude-code,copilot-cli,kiro-cli}.*` fanout — the
#   factory does NOT delegate to those upstream modules anymore. The
#   factory-of-factory callbacks implement the fanout directly under
#   `home.file` / `files.*` / whatever backend is chosen in the
#   "mkAiApp backend dispatch" backlog item.
#
# When absorbing this file's logic into the factory, port by chunk:
# ai.claude.enable block → mkClaude config callback, etc. Preserve the
# assertion semantics (outside mkIf) and the gating rules documented in
# `.claude/rules/ai-module.md`.
# ============================================================================
#
# Unified AI configuration module (legacy).
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
# Usage (legacy, pre-factory):
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
  inherit (aiCommon) instructionModule lspServerModule mkCopilotLspConfig mkLspConfig;
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
