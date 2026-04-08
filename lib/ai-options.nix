# Source-of-truth option types for the ai.* shared option pool.
#
# Both modules/ai/default.nix (HM) and modules/devenv/ai.nix (devenv)
# import option types from this file. Phase 2's backend adapters
# (lib/mk-ai-ecosystem-{hm,devenv}-module.nix) also reference these
# types when declaring per-ecosystem extension points like
# ai.<eco>.skills, ai.<eco>.instructions, etc.
#
# Centralizing the types here means a new shared category is added
# by editing one file, and all consumers (HM module, devenv module,
# backend adapters) pick up the new option uniformly.
#
# instructionModule and lspServerModule originate in lib/ai-common.nix
# and are re-exported here so consumers have a single import surface.
#
# No behavior change in Phase 1 -- this file just relocates types.
# See dev/notes/ai-transformer-design.md for the broader plan.
{lib}: let
  aiCommon = import ./ai-common.nix {inherit lib;};
  inherit (aiCommon) instructionModule lspServerModule;

  # Skills option: attrset of name -> path. Each path is a directory
  # whose contents become the skill's installed files.
  skillsOption = lib.mkOption {
    type = lib.types.attrsOf lib.types.path;
    default = {};
    description = ''
      Shared skills (directory paths). Identical format across ecosystems.
      Injected at mkDefault priority so per-CLI skills win.
    '';
  };

  # Instructions option: attrset of name -> instruction submodule
  # (text, paths, description). Body is shared across ecosystems;
  # frontmatter is generated per-ecosystem at fanout time.
  instructionsOption = lib.mkOption {
    type = lib.types.attrsOf instructionModule;
    default = {};
    description = ''
      Shared instructions with optional path scoping. Body is shared;
      frontmatter is generated per ecosystem.
    '';
  };

  # LSP server option: attrset of name -> { package, extensions, ... }.
  # Transformed per-ecosystem at fanout time via the ecosystem
  # record's translators.lspServer function.
  lspServersOption = lib.mkOption {
    type = lib.types.attrsOf lspServerModule;
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

  # Environment variables option: attrset of name -> string value.
  environmentVariablesOption = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = {};
    description = "Shared environment variables for all enabled CLIs.";
  };

  # Settings option: typed submodule for normalized cross-ecosystem
  # settings (model, telemetry). Each ecosystem's translator maps
  # these to its native key shape.
  settingsOption = lib.mkOption {
    type = lib.types.submodule {
      options = {
        model = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Default model -- translated per ecosystem.";
        };
        telemetry = lib.mkOption {
          type = lib.types.nullOr lib.types.bool;
          default = null;
          description = "Enable/disable telemetry -- translated per ecosystem.";
        };
      };
    };
    default = {};
    description = "Normalized settings translated to ecosystem-specific keys.";
  };
in {
  inherit
    environmentVariablesOption
    instructionModule
    instructionsOption
    lspServerModule
    lspServersOption
    settingsOption
    skillsOption
    ;
}
