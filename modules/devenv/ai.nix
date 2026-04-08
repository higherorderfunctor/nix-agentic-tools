# Unified AI configuration module for devenv.
#
# Single source of truth for shared config across Claude Code, Copilot,
# and Kiro in devenv context. Fans out to individual devenv modules via
# mkDefault so per-ecosystem config always wins.
#
# Pattern mirrors the home-manager modules/ai/default.nix but targets
# devenv's files.* instead of home.file.
#
# Each ai.{claude,copilot,kiro}.enable is the SOLE gate for that CLI's
# fanout — it also implicitly enables the corresponding devenv module
# (claude.code.enable, copilot.enable, kiro.enable), so consumers don't
# need to set enable twice. There is no master ai.enable switch;
# enabling at least one ecosystem sub-option is the activation.
# Parity with the home-manager ai module (dropped ai.enable in f2e911c).
#
# Usage:
#   ai = {
#     claude.enable = true;   # also sets claude.code.enable
#     copilot.enable = true;  # also sets copilot.enable
#     kiro.enable = true;     # also sets kiro.enable
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
    types
    ;

  aiCommon = import ../../lib/ai-common.nix {inherit lib;};
  inherit (aiCommon) instructionModule lspServerModule mkCopilotLspConfig mkLspConfig;

  # Legacy `aiTransforms` shape compat. Pre-factory this was
  # `pkgs.fragments-ai.passthru.transforms`, dissolved in M9 into
  # `lib/ai/transformers/*.nix`. The new transformers export raw
  # `{ <name>Transformer, render }` records where `render` has no
  # curried package/name context. Rebuild the curried shape inline
  # from `mkRenderer` + each ecosystem's transformer so the existing
  # fanout call sites below keep working without a wholesale rewrite.
  # This module is slated for absorption into
  # `packages/<name>/lib/mk<Name>.nix` config callbacks — see
  # `docs/plan.md` "Ideal architecture gate" for the backlog entry.
  fragmentsLib = import ../../lib/fragments.nix {inherit lib;};
  inherit (import ../../lib/ai/transformers/claude.nix {inherit lib;}) claudeTransformer;
  inherit (import ../../lib/ai/transformers/copilot.nix {inherit lib;}) copilotTransformer;
  inherit (import ../../lib/ai/transformers/kiro.nix {inherit lib;}) kiroTransformer;
  aiTransforms = {
    claude = {package}: fragmentsLib.mkRenderer claudeTransformer {inherit package;};
    copilot = fragmentsLib.mkRenderer copilotTransformer {};
    kiro = {name}: fragmentsLib.mkRenderer kiroTransformer {inherit name;};
  };

  cfg = config.ai;

  # Check if an option path exists (returns true if defined, even if not set).
  hasOpt = path: lib.hasAttrByPath path config;
in {
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
        };
      };
      default = {};
      description = ''
        Claude Code ecosystem configuration.

        Note: buddy customization is HM-only (devenv is per-project,
        buddy is per-user). Use the home-manager `programs.claude-code.buddy`
        or `ai.claude.buddy` option instead.
      '';
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

  config = mkMerge [
    # Shared environment variables — merge into devenv env for all ecosystems
    (mkIf (cfg.environmentVariables != {}) {
      env = lib.mapAttrs (_: mkDefault) cfg.environmentVariables;
    })

    # Claude Code — delegates skills through claude.code.skills
    # (from the claude-code-skills extension module). ai.claude.enable
    # flips claude.code.enable via mkDefault.
    (mkIf cfg.claude.enable (mkMerge [
      {
        claude.code.enable = mkDefault true;
        claude.code.skills = lib.mapAttrs (_: mkDefault) cfg.skills;
        files =
          # Instructions as Claude rules with frontmatter
          concatMapAttrs (name: instr: {
            ".claude/rules/${name}.md".text = mkDefault (aiTransforms.claude {package = name;} instr);
          })
          cfg.instructions;
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

    # Copilot — uses copilot.* options.
    # ai.copilot.enable flips copilot.enable via mkDefault.
    (mkIf cfg.copilot.enable {
      copilot = {
        enable = mkDefault true;
        environmentVariables = lib.mapAttrs (_: mkDefault) cfg.environmentVariables;
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

    # Kiro — uses kiro.* options.
    # ai.kiro.enable flips kiro.enable via mkDefault.
    (mkIf cfg.kiro.enable {
      kiro = {
        enable = mkDefault true;
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
          mkDefault (aiTransforms.kiro {inherit name;} instr))
        cfg.instructions;
      };
    })
  ];
}
