# claude.code.skills — devenv extension that adds a `skills`
# option to upstream devenv's claude.code module.
#
# Upstream devenv (cachix/devenv src/modules/integrations/claude.nix)
# does not yet expose a skills option — see cachix/devenv#2441.
# This extension adds it, mirroring how modules/claude-code-buddy/
# extends HM's programs.claude-code with the `buddy` option.
#
# Uses the mkDevenvSkillEntries walker from lib/hm-helpers.nix to
# produce per-leaf-file `files.*` entries (Layout B parity with HM's
# recursive = true), since devenv's native files option has no
# recursive walk of its own.
#
# When upstream devenv ships claude.code.skills, this whole module
# gets dropped (or refactored to delegate through the upstream
# option). The ai.nix delegation point stays the same.
{
  config,
  lib,
  ...
}: let
  inherit (lib) mkOption types;
  inherit (import ../../../lib/hm-helpers.nix {inherit lib;}) mkDevenvSkillEntries;
  cfg = config.claude.code.skills;
in {
  options.claude.code.skills = mkOption {
    type = types.attrsOf types.path;
    default = {};
    description = ''
      Skill directories to expose under `.claude/skills/<name>/`.
      Each value is a path to a skill directory containing
      `SKILL.md` and any supporting files. The directory tree is
      walked at evaluation time and per-file symlinks are emitted
      via devenv `files.*` entries, matching the on-disk layout
      HM produces with `recursive = true` on
      `home.file.".claude/skills/<name>"`.
    '';
    example = lib.literalExpression ''
      {
        stack-fix = ./skills/stack-fix;
        stack-plan = ./skills/stack-plan;
      }
    '';
  };

  config = lib.mkIf (cfg != {}) {
    files = mkDevenvSkillEntries ".claude" cfg;
  };
}
