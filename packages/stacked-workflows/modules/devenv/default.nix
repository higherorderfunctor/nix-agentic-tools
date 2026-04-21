# Stacked-workflows devenv module.
#
# Project-scope contributions: skills, instructions, reference docs.
# These were incorrectly placed in the HM module originally (see
# `docs/stacked-workflows-scope-fix-plan.md`) — moving them here so
# sws-prefixed content lands in project-local `.claude/*` instead of
# leaking to the user's personal `~/.claude/*` scope.
#
# Picked up by `collectFacet ["modules" "devenv"]` in flake.nix.
#
# The `enable` option is declared here (independently of the HM
# module's `enable`) because HM and devenv run separate evalModules
# invocations — each needs its own option tree. When the same repo
# loads both, consumers can enable independently or in tandem.
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

  # Module-relative path literal — must be `./` literal (not a
  # `builtins.path` result) so downstream `lib.isPath` guards pass.
  skillsRepo = ../../skills;
in {
  options.stacked-workflows = {
    enable = lib.mkEnableOption "stacked workflow skills, instructions, and references (project-local devenv scope)";
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    # ── Skills fanout to shared pool (devenv eval) ─────────────────────
    # `ai.skills` here populates DEVENV's eval of the shared pool.
    # Claude/Kiro/Copilot devenv factories consume it via
    # `mergedSkills` in devenvTransform. Does NOT leak to HM —
    # separate eval contexts.
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

    # ── Instructions fanout to shared pool (devenv eval) ───────────────
    {
      ai.instructions = [
        {
          name = "stacked-workflows";
          inherit (composed) text;
          description = "Stacked workflow routing table and skill usage";
        }
      ];
    }

    # ── Reference docs written as project-local files ──────────────────
    # Each enabled Claude consumer sees these at `.claude/references/`
    # relative to the devenv root. `files.<path>.source` handles
    # individual .md files fine (no recursion needed — flat dir).
    (let
      refFiles =
        lib.filterAttrs (n: _: lib.hasSuffix ".md" n)
        (builtins.readDir swsContent.passthru.referencesDir);
    in {
      files = lib.mapAttrs' (name: _:
        lib.nameValuePair
        ".claude/references/${name}"
        {source = "${swsContent.passthru.referencesDir}/${name}";})
      refFiles;
    })
  ]);
}
