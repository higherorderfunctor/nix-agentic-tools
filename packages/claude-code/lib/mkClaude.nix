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
    config = {
      cfg,
      mergedServers,
      mergedInstructions,
      mergedSkills,
    }:
      lib.mkMerge [
        # Delegate to upstream programs.claude-code.* where upstream
        # provides the capability. mkDefault lets consumers override.
        {
          programs.claude-code = {
            enable = lib.mkDefault true;
            package = lib.mkDefault cfg.package;
            skills = lib.mapAttrs (_: lib.mkDefault) mergedSkills;
            settings = lib.mkMerge [
              cfg.settings
              (lib.optionalAttrs (mergedServers != {}) {mcpServers = mergedServers;})
            ];
          };
        }
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
        # Per-instruction rule files — write .claude/rules/<name>.md
        # for each instruction entry that carries a `name` field. This
        # is a gap in upstream programs.claude-code (no per-rule file
        # option), so we write home.file directly. Entries without a
        # `name` field flow only into the baseline aggregated render
        # at .claude/CLAUDE.md (handled by hmTransform's baseline).
        (let
          fragmentsLib = import ../../../lib/fragments.nix {inherit lib;};
          inherit (import ../../../lib/ai/transformers/claude.nix {inherit lib;}) claudeTransformer;
          named = builtins.filter (i: i ? name) mergedInstructions;
        in {
          home.file = lib.listToAttrs (map (instr: {
              name = ".claude/rules/${instr.name}.md";
              value.text = fragmentsLib.mkRenderer claudeTransformer {package = instr.name;} instr;
            })
            named);
        })
        # Auto-set ENABLE_LSP_TOOL=1 when MCP servers are present.
        # Mirrors the legacy modules/ai/default.nix behavior where
        # any populated server pool implied LSP-tool wiring.
        (lib.mkIf (mergedServers != {}) {
          programs.claude-code.settings.env.ENABLE_LSP_TOOL = lib.mkDefault "1";
        })
      ];
  };
  # Devenv-specific projection (no buddy; devenv doesn't do activation scripts the same way)
  devenv = {
    options = {};
    config = {
      cfg,
      mergedServers,
      mergedInstructions,
      mergedSkills,
    }:
      lib.mkMerge [
        # Delegate to upstream devenv claude.code.* where upstream
        # provides the capability.
        {
          claude.code = {
            enable = lib.mkDefault true;
            mcpServers = mergedServers;
            env = cfg.settings.env or {};
          };
        }
        # Gap writes — per-instruction rule files. devenv has no
        # per-rule option, so we write files.* directly. Entries
        # without a `name` field flow into the baseline aggregate
        # render at .claude/CLAUDE.md (handled by devenvTransform).
        (let
          fragmentsLib = import ../../../lib/fragments.nix {inherit lib;};
          inherit (import ../../../lib/ai/transformers/claude.nix {inherit lib;}) claudeTransformer;
          named = builtins.filter (i: i ? name) mergedInstructions;
        in {
          files = lib.listToAttrs (map (instr: {
              name = ".claude/rules/${instr.name}.md";
              value.text = fragmentsLib.mkRenderer claudeTransformer {package = instr.name;} instr;
            })
            named);
        })
        # Skills — devenv has no upstream skills option on
        # claude.code (cachix/devenv#2441), so we write per-leaf
        # files.* entries via the mkDevenvSkillEntries walker. The
        # walker mirrors HM `recursive = true` in user space because
        # devenv `files.*.source` cannot recurse a directory itself.
        (let
          helpers = import ../../../lib/hm-helpers.nix {inherit lib;};
        in {
          files = helpers.mkDevenvSkillEntries ".claude" mergedSkills;
        })
      ];
  };
}
