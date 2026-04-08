# Unified AI configuration module.
#
# Single source of truth for shared config across Claude Code, Copilot CLI,
# and Kiro CLI. Per-ecosystem fanout is driven by ecosystem records
# (lib/ai-ecosystems/<name>.nix) and the HM adapter
# (lib/mk-ai-ecosystem-hm-module.nix). This file contains only:
#   - Shared option declarations (ai.skills, ai.instructions,
#     ai.lspServers, ai.environmentVariables, ai.settings)
#   - Cross-ecosystem assertions (shared-config-requires-enabled-CLI,
#     claude buddy validations)
#   - The imports list that pulls in the per-ecosystem upstream HM
#     modules (programs.claude-code via claude-code-buddy,
#     programs.copilot-cli, programs.kiro-cli) AND the
#     adapter-generated modules (one per ecosystem record).
#
# Each ai.{claude,copilot,kiro}.enable is the sole gate for that
# ecosystem's fanout — it also implicitly enables the corresponding
# upstream module via the adapter's mkDefault on
# programs.<cli>.enable. There is no master ai.enable switch;
# enabling at least one ecosystem sub-option is the activation.
#
# Adding a new ecosystem to ai.* is now:
#   1. Create lib/ai-ecosystems/<name>.nix with a complete record
#      (markdownTransformer, translators, layout, upstream, extraOptions)
#   2. Add (mkAiEcosystemHmModule (import ../../lib/ai-ecosystems/<name>.nix
#      {inherit lib;})) to this file's imports list
# No per-ecosystem fanout code changes to this file needed.
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
  ...
}: let
  inherit (lib) mkMerge optionals;

  aiOptions = import ../../lib/ai-options.nix {inherit lib;};

  cfg = config.ai;

  mkAiEcosystemHmModule = import ../../lib/mk-ai-ecosystem-hm-module.nix {inherit lib;};
in {
  # The first three imports pull in the upstream HM modules whose
  # option paths the adapter-generated modules below reference
  # (programs.claude-code.*, programs.copilot-cli.*,
  # programs.kiro-cli.*). The remaining three are the per-ecosystem
  # adapter-generated modules.
  #
  # Each ecosystem record is imported DIRECTLY from
  # lib/ai-ecosystems/<name>.nix rather than via
  # pkgs.fragments-ai.passthru.records.<name>: the module system
  # evaluates `imports` before `_module.args.pkgs` is available, so
  # reading `pkgs` here triggers infinite recursion through
  # `_module.freeformType`. The lib/ai-ecosystems/ files are the
  # single source of truth that packages/fragments-ai/default.nix
  # also re-exports via passthru.records.
  imports = [
    ../claude-code-buddy
    ../copilot-cli
    ../kiro-cli
    (mkAiEcosystemHmModule (import ../../lib/ai-ecosystems/claude.nix {inherit lib;}))
    (mkAiEcosystemHmModule (import ../../lib/ai-ecosystems/copilot.nix {inherit lib;}))
    (mkAiEcosystemHmModule (import ../../lib/ai-ecosystems/kiro.nix {inherit lib;}))
  ];

  # Shared option declarations. The per-ecosystem options
  # (ai.<eco>.enable, ai.<eco>.package, ai.claude.buddy) are
  # declared by the adapter-generated modules above.
  options.ai = {
    skills = aiOptions.skillsOption;
    instructions = aiOptions.instructionsOption;
    lspServers = aiOptions.lspServersOption;
    environmentVariables = aiOptions.environmentVariablesOption;
    settings = aiOptions.settingsOption;
  };

  # Cross-ecosystem assertions only. Per-ecosystem fanout config
  # is produced by the adapter-generated modules above.
  config = mkMerge [
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
  ];
}
