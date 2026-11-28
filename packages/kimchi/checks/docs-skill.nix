# Contracts for the opt-in `kimchi-docs` skill.
#
# Shared `web-docs-fixtures` covers fetching and updating both documentation
# owners. These checks read the installed snapshot and its delivered skill.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) checkRows deliveredFiles evalDevenv evalHm mkTest;
  workflowsPackage = pkgs.ai.kimchiExtensions.kimchi-workflows;

  # Home Manager delivers the skill to the user harness; devenv delivers it to
  # the project's `.kimchi/skills`, the native project-scope root.
  skillDir = ".config/kimchi/harness/skills/kimchi-docs";
  devenvSkillDir = ".kimchi/skills/kimchi-docs";

  runtimesOn = {
    ai.claude.enable = true;
    ai.kimchi.enable = true;
  };
  enable = lib.recursiveUpdate runtimesOn {ai.programs.kimchi-docs.enable = true;};

  hmOff = evalHm runtimesOn;
  devenvOff = evalDevenv runtimesOn;
  hmOn = evalHm enable;
  devenvOn = evalDevenv enable;

  # What each backend delivers at or under a skill directory. The directory
  # key itself is included so that a whole-directory delivery is caught. The
  # skill lands as these leaves: SKILL.md, and the snapshot and workflows
  # directory symlinks as ONE link each, never walked into.
  skillKeys = dir: result: lib.filter (n: n == dir || lib.hasPrefix "${dir}/" n) (builtins.attrNames (deliveredFiles result.config));
  skillLeaves = dir: map (name: "${dir}/${name}") ["SKILL.md" "snapshot" "workflows"];
  hmLeaf = name: (deliveredFiles hmOn.config)."${skillDir}/${name}".source;

  # Deliver the skill to Claude under three semble shapes and read the SKILL.md
  # each one produced. Built rather than evaluated: reading a derivation's
  # output at eval time is import-from-derivation.
  claudeSkill = semble:
    (evalHm (lib.recursiveUpdate enable {ai.programs.semble = semble;}))
    .config.ai.claude.skills.kimchi-docs;

  spliceVariants = {
    # No semble at all -> ordinary text search.
    plain = claudeSkill {};
    # CLI instructions selected (and MCP inherits `enable`, so this is the
    # CLI+MCP case) -> CLI directions only.
    cli = claudeSkill {
      enable = true;
      cli.instructions.enable = true;
    };
    # MCP only: `enable` selects MCP, `cli.instructions` is an explicit opt-in
    # that stays off -> MCP directions.
    mcp = claudeSkill {enable = true;};
  };
in {
  checks = {
    # Assert that the delivered snapshot link targets the pinned derivation.
    # The shared web-docs replay checks the packaged pages.
    kimchi-docs-skill-snapshot = pkgs.runCommand "kimchi-docs-skill-snapshot" {} ''
      # Full strict mode is required here: stdenv does not set every flag (#909).
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      skill_md=${hmLeaf "SKILL.md"}
      snapshot=${hmLeaf "snapshot"}
      workflows=${hmLeaf "workflows"}

      require() {
        if ! eval "$2"; then
          printf 'kimchi-docs skill: %s\n' "$1" >&2
          printf '  delivered leaves: %s %s %s\n' "$skill_md" "$snapshot" "$workflows" >&2
          exit 1
        fi
      }

      require "SKILL.md has lost its name: kimchi-docs frontmatter, so no runtime will match it" \
        "grep -qx 'name: \"kimchi-docs\"' \"\$skill_md\""
      require "the snapshot link does not point at the packaged docs.kimchi-docs derivation (${pkgs.docs.kimchi-docs})" \
        '[ "$(readlink "$snapshot")" = ${pkgs.docs.kimchi-docs} ]'
      require "the workflows link does not point at the patched installed workflows package" \
        '[ "$(readlink "$workflows")" = ${workflowsPackage} ]'
      require "the workflows README is unreadable through the skill" '[ -s "$workflows/README.md" ]'
      require "SKILL.md omits the workflows source directions" 'grep -q workflows/src "$skill_md"'

      echo PASS > "$out"
    '';

    # Asserts: SKILL.md carries the search directions that match the semble
    # integration actually delivered to that runtime.
    kimchi-docs-skill-semble-splice = pkgs.runCommand "kimchi-docs-skill-semble-splice" {} ''
      # Full strict mode is required here: stdenv does not set every flag (#909).
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      check_search() {
        local variant=$1 skill=$2 required=$3 forbidden
        shift 3
        if ! grep -qF "$required" "$skill/SKILL.md"; then
          printf 'kimchi-docs skill (%s search): SKILL.md omits %s\n' "$variant" "$required" >&2
          exit 1
        fi
        for forbidden in "$@"; do
          if grep -qF "$forbidden" "$skill/SKILL.md"; then
            printf 'kimchi-docs skill (%s search): SKILL.md wrongly carries %s\n' "$variant" "$forbidden" >&2
            exit 1
          fi
        done
      }

      check_search cli ${spliceVariants.cli} 'semble search' 'mcp__semble__search'
      check_search mcp ${spliceVariants.mcp} 'mcp__semble__search' 'semble search'
      check_search plain ${spliceVariants.plain} 'rg -n' 'mcp__semble__search' 'semble search'

      echo PASS > "$out"
    '';

    module-kimchi-docs-skill = let
      copilotOnly = evalHm {
        ai.copilot.enable = true;
        ai.programs.kimchi-docs.enable = true;
      };
      kimchiOff = evalHm (lib.recursiveUpdate enable {
        ai.programs.kimchi-docs.runtimes.kimchi.enable = false;
      });
    in
      mkTest "kimchi-docs-skill" (checkRows "kimchi-docs skill delivery" {
        # The snapshot and workflows must stay one directory symlink each.
        devenv-enabled-delivers-exact-skill-leaves = skillKeys devenvSkillDir devenvOn == skillLeaves devenvSkillDir;
        devenv-off-does-not-deliver-skill-files = skillKeys devenvSkillDir devenvOff == [];
        hm-enabled-delivers-exact-skill-leaves = skillKeys skillDir hmOn == skillLeaves skillDir;
        hm-kimchi-override-suppresses-kimchi-skill = !(kimchiOff.config.ai.kimchi.skills ? kimchi-docs);
        hm-off-does-not-deliver-skill-files = skillKeys skillDir hmOff == [];
        # A package enable must not claim an undelivered consumer pool on HM.
        hm-unavailable-github-skills-pool-does-not-warn = copilotOnly.config.warnings == [];
      });
  };
}
