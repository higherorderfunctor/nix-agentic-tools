# Claude-specific factory-of-factory.
#
# Imported at flake-eval time into lib.ai.apps.mkClaude via the
# packages/claude-code/default.nix barrel and flake.nix's barrel walker.
# Callers (the HM module in ../modules/homeManager/default.nix) invoke
# it once to produce a full NixOS module function.
#
# Note: the mkAiApp config callback receives {cfg, mergedServers,
# mergedInstructions, mergedSkills} — it does NOT receive lib or pkgs.
# Those are closed over from the outer function arguments here.
{
  lib,
  pkgs,
  ...
}:
lib.ai.app.mkAiApp {
  name = "claude";
  transformers.markdown = lib.ai.transformers.claude;
  defaults = {
    package = pkgs.ai.claude-code;
    outputPath = ".claude/CLAUDE.md";
  };
  options = {
    buddy = lib.mkOption {
      type = lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "Claude buddy activation script";
          statePath = lib.mkOption {
            type = lib.types.str;
            default = ".local/state/claude-code-buddy";
            description = "Relative path under $HOME for buddy state.";
          };
        };
      };
      default = {enable = false;};
      description = "Claude-specific buddy activation options.";
    };
    memory = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to a file used as Claude's memory.";
    };
    # NOTE: `settings` is declared here but NOT yet rendered to disk.
    # Writing settings JSON to ~/.claude/settings.json (or similar) is
    # deferred to the milestone that wires the transformers + outputPath
    # rendering pipeline. Until then, values assigned to ai.claude.settings
    # are accepted without error but silently ignored. Flagged in the
    # Milestone 2 code review.
    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
      description = "Freeform settings passed to Claude's config file (rendering deferred to a later milestone).";
    };
  };
  config = {cfg, ...}:
    lib.mkMerge [
      (lib.mkIf cfg.buddy.enable {
        # Buddy activation script — stubbed for milestone 2. Full
        # byte-level port from archive/phase-2a-refactor:modules/claude-code-buddy/
        # can follow in a separate commit if a running consumer needs it.
        home.activation.claudeBuddy = lib.hm.dag.entryAfter ["writeBoundary"] ''
          $DRY_RUN_CMD mkdir -p "$HOME/${cfg.buddy.statePath}"
        '';
      })
      (lib.mkIf (cfg.memory != null) {
        home.file.".claude/memory".source = cfg.memory;
      })
    ];
}
