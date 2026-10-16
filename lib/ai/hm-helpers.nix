# Shared helpers for AI CLI modules (copilot-cli, kiro-cli, devenv).
#
{lib}: {
  # ── File entry builders ──────────────────────────────────────────────

  # One skill tree as STAGED entries (`ai.<runtime>._generatedFiles`), for
  # every runtime and both backends; layer 1 and the files engine deliver them.
  #
  # A directory skill is one entry with a directory source, which the engine
  # walks into one link per leaf on both backends. A single-file skill becomes
  # its own `SKILL.md`.
  #
  # `recursive = false` with a directory source is Codex's shape, and it is a
  # measured consumer fact rather than a preference: Codex discovers a skill
  # when the skill DIRECTORY is itself a symlink, and not when the backend
  # creates a real directory of symlinked leaves.
  #
  # `builtins.readFileType` rather than `lib.isPath`, because a skill that
  # comes from a package is an interpolated STRING, and treating that as a
  # single file writes the path itself as the file's content. The source is
  # always interpolated: a path-typed tree then enters the store once, so a
  # relative symlink between two of its leaves still resolves.
  mkSkillFiles = {
    configDir,
    recursive ? true,
    skills,
  }:
    lib.mapAttrs' (
      name: source: let
        entry = {
          content.source = "${source}";
          surface = "skills";
        };
      in
        if (builtins.readFileType source) == "directory"
        then lib.nameValuePair "${configDir}/skills/${name}" (entry // {inherit recursive;})
        else
          assert lib.assertMsg recursive
          "mkSkillFiles: skill '${name}' must resolve to a directory";
            lib.nameValuePair "${configDir}/skills/${name}/SKILL.md" entry
    )
    skills;
}
