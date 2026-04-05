# Unified AI configuration module.
#
# Single source of truth for shared config across Claude Code, Copilot CLI,
# and Kiro CLI. Fans out to individual CLI modules via mkDefault so
# per-CLI config always wins.
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
  options,
  ...
}: let
  inherit
    (lib)
    attrByPath
    concatMapAttrs
    filterAttrs
    mkDefault
    mkEnableOption
    mkIf
    mkMerge
    mkOption
    optionalAttrs
    types
    ;

  cfg = config.ai;

  # Instruction submodule: shared semantic fields, translated per ecosystem.
  instructionModule = types.submodule {
    options = {
      text = mkOption {
        type = types.lines;
        description = "Instruction body (markdown).";
      };
      paths = mkOption {
        type = types.nullOr (types.listOf types.str);
        default = null;
        description = ''
          File path globs this instruction applies to. null = always loaded.
          Translated per ecosystem:
          - Claude: paths: frontmatter
          - Kiro: inclusion: fileMatch + fileMatchPattern:
          - Copilot: applyTo: glob
        '';
      };
      description = mkOption {
        type = types.str;
        default = "";
        description = "Short description (used by Claude and Kiro frontmatter).";
      };
    };
  };

  # Generate Claude rules frontmatter
  mkClaudeRule = name: instr: let
    pathsYaml =
      if instr.paths != null
      then "\npaths:\n${lib.concatMapStringsSep "\n" (p: "  - \"${p}\"") instr.paths}"
      else "";
    descYaml =
      if instr.description != ""
      then "\ndescription: ${instr.description}"
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
    patternYaml =
      if instr.paths != null
      then "\nfileMatchPattern: \"${lib.concatStringsSep "," instr.paths}\""
      else "";
    descYaml =
      if instr.description != ""
      then "\ndescription: ${instr.description}"
      else "";
  in ''
    ---
    name: ${name}${descYaml}
    inclusion: ${inclusion}${patternYaml}
    ---

    ${instr.text}
  '';

  # Generate Copilot instruction frontmatter
  mkCopilotInstruction = name: instr: let
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

  # Check if a module option path exists (use options, not config)
  hasModule = path:
    (attrByPath path null options) != null;
in {
  options.ai = {
    enable = mkEnableOption "unified AI configuration across Claude, Copilot, and Kiro";

    enableClaude = mkOption {
      type = types.bool;
      default = false;
      description = "Fan out shared config to programs.claude-code.";
    };

    enableCopilot = mkOption {
      type = types.bool;
      default = false;
      description = "Fan out shared config to programs.copilot-cli.";
    };

    enableKiro = mkOption {
      type = types.bool;
      default = false;
      description = "Fan out shared config to programs.kiro-cli.";
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

    environmentVariables = mkOption {
      type = types.attrsOf types.str;
      default = {};
      description = "Shared environment variables for all enabled CLIs.";
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
          assertion = cfg.enableCopilot -> hasModule ["programs" "copilot-cli" "enable"];
          message = "ai.enableCopilot requires programs.copilot-cli to be available.";
        }
        {
          assertion = cfg.enableKiro -> hasModule ["programs" "kiro-cli" "enable"];
          message = "ai.enableKiro requires programs.kiro-cli to be available.";
        }
        {
          assertion =
            cfg.skills
            != {}
            || cfg.instructions != {}
            || cfg.environmentVariables != {}
            -> cfg.enableClaude || cfg.enableCopilot || cfg.enableKiro;
          message = "ai has shared config but no CLIs enabled. Set at least one of enableClaude, enableCopilot, enableKiro.";
        }
      ];
    }

    # MCP bridging: ai doesn't have its own mcpServers option.
    # Users configure programs.mcp.servers directly and each CLI's
    # enableMcpIntegration picks them up. This avoids double-injection.

    # Claude Code — uses home.file for both rules and skills to avoid
    # depending on the upstream programs.claude-code module being imported.
    (mkIf cfg.enableClaude {
      home.file =
        # Instructions as Claude rules with frontmatter
        (concatMapAttrs (name: instr: {
            ".claude/rules/${name}.md" = {
              text = mkDefault (mkClaudeRule name instr);
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
    })

    # Copilot CLI
    (mkIf cfg.enableCopilot {
      programs.copilot-cli = {
        skills = lib.mapAttrs (_: mkDefault) cfg.skills;
        instructions = lib.mapAttrs (name: instr:
          mkDefault (mkCopilotInstruction name instr))
        cfg.instructions;
        environmentVariables =
          lib.mapAttrs (_: mkDefault) cfg.environmentVariables;
      };
    })

    # Kiro CLI
    (mkIf cfg.enableKiro {
      programs.kiro-cli = {
        steering = lib.mapAttrs (name: instr:
          mkDefault (mkKiroSteering name instr))
        cfg.instructions;
        skills = lib.mapAttrs (_: mkDefault) cfg.skills;
        environmentVariables =
          lib.mapAttrs (_: mkDefault) cfg.environmentVariables;
      };
    })
  ]);
}
