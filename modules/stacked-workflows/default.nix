# Home-manager module for stacked-workflow-skills.
#
# Convenience wrapper for global/per-user installation. Sets git config
# presets and wires AI tool integrations (Claude Code, Kiro, Copilot).
#
# Usage:
#   imports = [ inputs.nix-agentic-tools.homeManagerModules.stacked-workflows ];
#   stacked-workflows.enable = true;
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.stacked-workflows;

  fragments = import ../../lib/fragments.nix {inherit lib;};
  aiTransforms = pkgs.fragments-ai.passthru.transforms;

  swsContent = pkgs.stacked-workflows-content;

  composed = fragments.compose {
    fragments = builtins.attrValues swsContent.passthru.fragments;
  };

  self = {
    inherit (swsContent.passthru) referencesDir skillsDir;
    instructionsClaude = aiTransforms.claude {package = "stacked-workflows";} composed;
    instructionsCopilot = aiTransforms.copilot composed;
    instructionsKiro = aiTransforms.kiro {name = "stacked-workflows";} composed;
    gitConfig = import ./git-config.nix;
    gitConfigFull = import ./git-config-full.nix;
  };

  # Apply mkDefault to every leaf value in a nested attrset so users can
  # override individual keys at normal priority.
  mkDefaultRecursive = lib.mapAttrsRecursive (_path: lib.mkDefault);

  gitSettings = {
    "full" = self.gitConfigFull;
    "minimal" = self.gitConfig;
    "none" = {};
  };

  claudeAvailable =
    lib.attrByPath ["programs" "claude-code" "enable"] false config;
in {
  options.stacked-workflows = {
    enable = lib.mkEnableOption "stacked workflow skills and references";

    gitPreset = lib.mkOption {
      type = lib.types.enum ["full" "minimal" "none"];
      default = "none";
      description = ''
        Git configuration preset for stacked workflows.

        - `"minimal"` — required + strongly recommended settings
        - `"full"` — all recommended settings (branchless, revise, general git)
        - `"none"` — no git configuration changes

        All values are set at `mkDefault` priority so you can override
        individual keys at normal priority in `programs.git.settings`.
      '';
    };

    integrations = {
      claude = {
        enable = lib.mkEnableOption "Claude Code integration";
      };

      copilot = {
        enable = lib.mkEnableOption "GitHub Copilot CLI integration (gh copilot)";
      };

      kiro = {
        enable = lib.mkEnableOption "Kiro integration";
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    # ── Assertions ─────────────────────────────────────────────────────
    {
      assertions = [
        {
          assertion =
            !(cfg.gitPreset
              != "none"
              && (lib.attrByPath ["pull" "ff"] null
                config.programs.git.settings)
              != null);
          message = ''
            programs.git.settings.pull.ff conflicts with
            stacked-workflows.gitPreset.

            Since Git 2.34, pull.ff = "only" takes priority over
            pull.rebase = true, causing "git pull" to fail when local
            commits exist. Remove pull.ff from your git settings or set
            stacked-workflows.gitPreset = "none".
          '';
        }
        {
          assertion =
            !(cfg.integrations.claude.enable && !claudeAvailable);
          message = ''
            stacked-workflows.integrations.claude.enable requires
            programs.claude-code to be imported and enabled.

            Either enable programs.claude-code.enable = true or disable
            the integration: stacked-workflows.integrations.claude.enable = false;
          '';
        }
      ];
    }

    # ── Git configuration ──────────────────────────────────────────────
    (lib.mkIf (cfg.gitPreset != "none") {
      programs.git.settings = mkDefaultRecursive gitSettings.${cfg.gitPreset};
    })

    # ── Claude Code ────────────────────────────────────────────────────
    (lib.mkIf (cfg.integrations.claude.enable && claudeAvailable) {
      programs.claude-code = {
        # Per-skill entries merge with skills from other modules.
        # `self.skillsDir + "/stack-*"` is path ADDITION (result is a
        # Nix path), not string interpolation (which would produce a
        # string and trigger the upstream HM `mkSkillEntry` fallback
        # that writes the path itself as SKILL.md text content —
        # matching lib.isPath is a hard type check, not a value check).
        skills = {
          stack-fix = self.skillsDir + "/stack-fix";
          stack-plan = self.skillsDir + "/stack-plan";
          stack-split = self.skillsDir + "/stack-split";
          stack-submit = self.skillsDir + "/stack-submit";
          stack-summary = self.skillsDir + "/stack-summary";
          stack-test = self.skillsDir + "/stack-test";
        };
      };
      # Per-file references — instructions + tool docs
      home.file = let
        refFiles =
          lib.filterAttrs (n: _: lib.hasSuffix ".md" n)
          (builtins.readDir self.referencesDir);
      in
        # Tool reference docs (git-absorb.md, philosophy.md, etc.)
        lib.mapAttrs' (name: _:
          lib.nameValuePair
          ".claude/references/${name}"
          {source = "${self.referencesDir}/${name}";})
        refFiles
        // {
          # Instruction file (routing table for consumers)
          ".claude/references/stacked-workflow.md".text =
            self.instructionsClaude;
        };
    })

    # ── Copilot CLI ────────────────────────────────────────────────────
    (lib.mkIf cfg.integrations.copilot.enable {
      home.file = {
        # Per-skill entries so user can add their own alongside.
        # Path addition keeps values as Nix paths; string
        # interpolation here would still work for `home.file.source`
        # (it accepts strings) but diverges from the idiom used
        # upstream and in the Claude branch above.
        ".copilot/skills/stack-fix".source = self.skillsDir + "/stack-fix";
        ".copilot/skills/stack-plan".source = self.skillsDir + "/stack-plan";
        ".copilot/skills/stack-split".source = self.skillsDir + "/stack-split";
        ".copilot/skills/stack-submit".source = self.skillsDir + "/stack-submit";
        ".copilot/skills/stack-summary".source = self.skillsDir + "/stack-summary";
        ".copilot/skills/stack-test".source = self.skillsDir + "/stack-test";
        ".copilot/instructions/stacked-workflow.md".text = self.instructionsCopilot;
      };
    })

    # ── Kiro ───────────────────────────────────────────────────────────
    (lib.mkIf cfg.integrations.kiro.enable {
      home.file = {
        # Per-skill entries so user can add their own alongside
        ".kiro/skills/stack-fix".source = self.skillsDir + "/stack-fix";
        ".kiro/skills/stack-plan".source = self.skillsDir + "/stack-plan";
        ".kiro/skills/stack-split".source = self.skillsDir + "/stack-split";
        ".kiro/skills/stack-submit".source = self.skillsDir + "/stack-submit";
        ".kiro/skills/stack-summary".source = self.skillsDir + "/stack-summary";
        ".kiro/skills/stack-test".source = self.skillsDir + "/stack-test";
        ".kiro/steering/stacked-workflow.md".text = self.instructionsKiro;
      };
    })
  ]);
}
