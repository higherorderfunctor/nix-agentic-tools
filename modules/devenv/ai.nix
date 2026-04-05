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

  cfg = config.ai;

  # Instruction submodule: shared semantic fields, translated per ecosystem.
  instructionModule = types.submodule {
    options = {
      description = mkOption {
        type = types.str;
        default = "";
        description = "Short description (used by Claude and Kiro frontmatter).";
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
      text = mkOption {
        type = types.lines;
        description = "Instruction body (markdown).";
      };
    };
  };

  # Generate Claude rules frontmatter
  mkClaudeRule = name: instr: let
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

    instructions = mkOption {
      type = types.attrsOf instructionModule;
      default = {};
      description = ''
        Shared instructions with optional path scoping. Body is shared;
        frontmatter is generated per ecosystem.
      '';
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
    # Claude Code — uses files.* for both rules and skills
    (mkIf cfg.enableClaude {
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
    })

    # Copilot — uses copilot.* options
    (mkIf cfg.enableCopilot {
      copilot = {
        instructions = lib.mapAttrs (name: instr:
          mkDefault (mkCopilotInstruction name instr))
        cfg.instructions;
        skills = lib.mapAttrs (_: mkDefault) cfg.skills;
      };
    })

    # Kiro — uses kiro.* options
    (mkIf cfg.enableKiro {
      kiro = {
        skills = lib.mapAttrs (_: mkDefault) cfg.skills;
        steering = lib.mapAttrs (name: instr:
          mkDefault (mkKiroSteering name instr))
        cfg.instructions;
      };
    })
  ]);
}
