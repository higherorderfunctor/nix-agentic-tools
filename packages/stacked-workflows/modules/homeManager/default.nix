# Stacked-workflows home-manager module (factory participant).
#
# Plain HM module (approach B) — does NOT use mkAiApp because
# stacked-workflows is a content package, not an AI CLI app. It has
# no binary, no settings, no MCP servers. It contributes:
#   - Skills to the shared ai.skills pool (consumed by all enabled CLIs)
#   - Instructions to the shared ai.instructions pool
#   - Git config presets to programs.git.settings
#
# Picked up by collectFacet ["modules" "homeManager"] in flake.nix.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.stacked-workflows;

  fragments = import ../../../../lib/fragments.nix {inherit lib;};

  swsContent = pkgs.stacked-workflows-content;

  composed = fragments.compose {
    fragments = builtins.attrValues swsContent.passthru.fragments;
    description = "Stacked workflow routing table and skill usage";
  };

  # Module-relative path literal for the source skills directory.
  # This MUST be a `./` path literal — see `.claude/rules/hm-modules.md`
  # "Nix path types" section. `builtins.path`, `filterSource`, and
  # `lib.cleanSourceWith` all return store-path *strings*, which fail
  # upstream HM's `mkSkillEntry` `lib.isPath` guard.
  skillsRepo = ../../skills;

  # Apply mkDefault to every leaf value in a nested attrset so users can
  # override individual keys at normal priority.
  mkDefaultRecursive = lib.mapAttrsRecursive (_path: lib.mkDefault);

  gitConfigMinimal = import ./git-config.nix;
  gitConfigFull = import ./git-config-full.nix;

  gitSettings = {
    "full" = gitConfigFull;
    "minimal" = gitConfigMinimal;
    "none" = {};
  };
in {
  options.stacked-workflows = {
    enable = lib.mkEnableOption "stacked workflow skills and references";

    gitPreset = lib.mkOption {
      type = lib.types.enum ["full" "minimal" "none"];
      default = "none";
      description = ''
        Git configuration preset for stacked workflows.

        - `"minimal"` -- required + strongly recommended settings
        - `"full"` -- all recommended settings (branchless, revise, general git)
        - `"none"` -- no git configuration changes

        All values are set at `mkDefault` priority so you can override
        individual keys at normal priority in `programs.git.settings`.
      '';
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
      ];
    }

    # ── Git configuration ──────────────────────────────────────────────
    (lib.mkIf (cfg.gitPreset != "none") {
      programs.git.settings = mkDefaultRecursive gitSettings.${cfg.gitPreset};
    })

    # ── Skills fanout to shared pool ───────────────────────────────────
    # Each enabled CLI picks up these skills via the ai.skills merge in
    # mkAiApp's hmTransform / devenvTransform.
    {
      ai.skills = lib.mapAttrs (_: lib.mkDefault) {
        sws-stack-fix = skillsRepo + "/stack-fix";
        sws-stack-plan = skillsRepo + "/stack-plan";
        sws-stack-split = skillsRepo + "/stack-split";
        sws-stack-submit = skillsRepo + "/stack-submit";
        sws-stack-summary = skillsRepo + "/stack-summary";
        sws-stack-test = skillsRepo + "/stack-test";
      };
    }

    # ── Instructions fanout to shared pool ─────────────────────────────
    # Each enabled CLI renders these via its own transformer.
    {
      ai.instructions = [
        {
          name = "stacked-workflows";
          inherit (composed) text;
          description = "Stacked workflow routing table and skill usage";
        }
      ];
    }

    # ── Reference directory ────────────────────────────────────────────
    # Symlink tool reference docs so CLIs can discover them.
    (let
      refFiles =
        lib.filterAttrs (n: _: lib.hasSuffix ".md" n)
        (builtins.readDir swsContent.passthru.referencesDir);
    in {
      home.file = lib.mapAttrs' (name: _:
        lib.nameValuePair
        ".claude/references/${name}"
        {source = "${swsContent.passthru.referencesDir}/${name}";})
      refFiles;
    })
  ]);
}
