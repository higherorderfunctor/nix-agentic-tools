# Contracts for the opt-in `kimchi-docs` skill.
#
# `kimchi-docs-links` lints the FETCHER script; it never opens the snapshot. The
# build check below is the first consumer that reads the packaged snapshot
# itself, so it is what makes `docs.kimchi-docs` more than bytes nothing reads.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) evalDevenv evalHm mkTest;

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

  devenvSkillKeys = result:
    lib.filter (name: lib.hasPrefix "${devenvSkillDir}/" name)
    (builtins.attrNames result.config.files);

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
      instructions.cli.enable = true;
    };
    # MCP only: `enable` selects MCP, `instructions.cli` is an explicit opt-in
    # that stays off -> MCP directions.
    mcp = claudeSkill {enable = true;};
  };
in {
  checks = {
    # Asserts: the skill delivered by the module still resolves to the packaged
    # snapshot AND that snapshot is readable through it, page contents included.
    kimchi-docs-skill-snapshot = pkgs.runCommand "kimchi-docs-skill-snapshot" {} ''
      # Full strict mode is required here: stdenv does not set every flag (#909).
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      skill=${hmOn.config.home.file.${skillDir}.source}

      require() {
        if ! eval "$2"; then
          printf 'kimchi-docs skill: %s\n' "$1" >&2
          printf '  skill directory: %s\n' "$skill" >&2
          exit 1
        fi
      }

      require "SKILL.md is missing or empty" '[ -s "$skill/SKILL.md" ]'
      require "SKILL.md has lost its name: kimchi-docs frontmatter, so no runtime will match it" \
        'grep -qx "name: kimchi-docs" "$skill/SKILL.md"'
      require "the snapshot link does not point at the packaged docs.kimchi-docs derivation (${pkgs.docs.kimchi-docs})" \
        '[ "$(readlink "$skill/snapshot")" = ${pkgs.docs.kimchi-docs} ]'
      for index in snapshot/llms.txt snapshot/docs/llms.txt; do
        require "the index $index is unreadable through the skill" '[ -s "$skill/$index" ]'
        require "the index $index does not name docs.kimchi.dev, so it is not the upstream index" \
          'grep -q docs.kimchi.dev "$skill/$index"'
      done
      require "the documentation page snapshot/docs/kimchi-cli.md is unreadable through the skill" \
        '[ -s "$skill/snapshot/docs/kimchi-cli.md" ]'

      pages="$(find -L "$skill/snapshot/docs" -name '*.md' -type f | wc -l)"
      if [ "$pages" -lt 40 ]; then
        printf 'kimchi-docs skill: only %s documentation pages are reachable at %s\n' \
          "$pages" "$skill/snapshot/docs" >&2
        printf '  expected at least 40; the snapshot shrank or the skill stopped pointing at it\n' >&2
        exit 1
      fi

      echo PASS > "$out"
    '';

    # Asserts: SKILL.md carries the search directions that match the semble
    # integration actually delivered to that runtime.
    kimchi-docs-skill-semble-splice = pkgs.runCommand "kimchi-docs-skill-semble-splice" {} ''
      # Full strict mode is required here: stdenv does not set every flag (#909).
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :

      expect() {
        if ! grep -qF "$3" "$2/SKILL.md"; then
          printf 'kimchi-docs skill (%s semble): SKILL.md omits %s\n' "$1" "$3" >&2
          exit 1
        fi
      }
      reject() {
        if grep -qF "$3" "$2/SKILL.md"; then
          printf 'kimchi-docs skill (%s semble): SKILL.md wrongly carries %s\n' "$1" "$3" >&2
          exit 1
        fi
      }

      expect none ${spliceVariants.plain} 'rg -n'
      reject none ${spliceVariants.plain} 'semble search'
      reject none ${spliceVariants.plain} 'mcp__semble__search'

      expect cli ${spliceVariants.cli} 'semble search'
      reject cli ${spliceVariants.cli} 'mcp__semble__search'

      expect mcp ${spliceVariants.mcp} 'mcp__semble__search'
      reject mcp ${spliceVariants.mcp} 'semble search'

      echo PASS > "$out"
    '';

    # Asserts: nothing is delivered until the portable enable is set.
    module-kimchi-docs-skill-opt-in = mkTest "kimchi-docs-skill-opt-in" (
      !(hmOff.config.ai.kimchi.skills ? kimchi-docs)
      && !(hmOff.config.ai.claude.skills ? kimchi-docs)
      && !(hmOff.config.home.file ? ${skillDir})
      && devenvSkillKeys devenvOff == []
    );

    # Asserts: enabling it mounts the skill in every runtime's pool and
    # materializes it on both backends — and that the snapshot stays ONE devenv
    # entry (the symlink), not one per snapshot file.
    module-kimchi-docs-skill-delivered = mkTest "kimchi-docs-skill-delivered" (
      hmOn.config.ai.kimchi.skills
      ? kimchi-docs
      && hmOn.config.ai.claude.skills ? kimchi-docs
      && hmOn.config.home.file.${skillDir}.recursive
      && lib.sort lib.lessThan (devenvSkillKeys devenvOn)
      == ["${devenvSkillDir}/SKILL.md" "${devenvSkillDir}/snapshot"]
    );

    # Asserts: a per-runtime `false` suppresses exactly that runtime.
    module-kimchi-docs-skill-runtime-override = mkTest "kimchi-docs-skill-runtime-override" (
      let
        result = evalHm (lib.recursiveUpdate enable {
          ai.kimchi.programs.kimchi-docs.enable = false;
        });
      in
        !(result.config.ai.kimchi.skills ? kimchi-docs)
        && result.config.ai.claude.skills ? kimchi-docs
    );
  };
}
