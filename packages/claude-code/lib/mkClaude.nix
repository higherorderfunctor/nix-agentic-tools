# Claude-specific factory-of-factory.
#
# Returns a backend-agnostic app record describing the Claude AI app.
# Backend-specific module functions are produced by applying
# `hmTransform` (HM) or `devenvTransform` (devenv) to this record.
#
# For now this is a minimal shape preserving the current behavior.
# Full fanout (skills, mcpServers, instructions files, buddy
# activation) is absorbed in Task 3 (A2) and Task 6 (A1).
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
  # Shared options (present in both backends)
  options = {
    memory = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to a file used as Claude's memory.";
    };
    # NOTE: `settings` is declared here but NOT yet rendered to disk.
    # Writing settings JSON to ~/.claude/settings.json requires a
    # backend-specific write (home.file for HM, files.* for devenv)
    # which is tracked by the `mkAiApp backend dispatch` backlog item
    # in docs/plan.md. Values assigned to ai.claude.settings are
    # accepted without error but silently ignored until that lands.
    settings = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
      description = "Freeform settings passed to Claude's config file (rendering tracked in docs/plan.md absorption backlog).";
    };
  };
  # HM-specific projection
  hm = {
    # HM-only options
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
        description = "Claude-specific buddy activation options (HM only).";
      };
    };
    config = {cfg, ...}:
      lib.mkMerge [
        (lib.mkIf cfg.buddy.enable {
          # Buddy activation script — placeholder only. The full 208-line
          # activation logic (fingerprint caching, sops-nix userId read,
          # Bun wrapper cli.js patching, companion reset on mismatch)
          # lives in `modules/claude-code-buddy/default.nix` as reference
          # content pending absorption into this callback. See the
          # `buddy absorption` entry under docs/plan.md "Ideal
          # architecture gate → Absorption backlog". Any port MUST
          # preserve the invariants in `.claude/rules/claude-code.md`
          # (no `exit` in activation, Bun-vs-Node hash consistency,
          # if/fi short-circuit, companion reset on fingerprint
          # mismatch).
          home.activation.claudeBuddy = lib.hm.dag.entryAfter ["writeBoundary"] ''
            $DRY_RUN_CMD mkdir -p "$HOME/${cfg.buddy.statePath}"
          '';
        })
        (lib.mkIf (cfg.memory != null) {
          home.file.".claude/memory".source = cfg.memory;
        })
      ];
  };
  # Devenv-specific projection (no buddy; devenv doesn't do activation scripts the same way)
  devenv = {
    options = {};
    config = _: {};
  };
}
