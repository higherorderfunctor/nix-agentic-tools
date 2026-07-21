# Generate the living-workflow skill directory with the XDG state base baked into
# SKILL.md (the @XDG_STATE_BASE@ token), copying references/ verbatim, and return
# its store-path STRING (its outPath).
#
# WHY a string, not the derivation: `ai.skills` is `attrsOf lib.types.path`, whose
# emission helpers decide the materialization. The repo's `mkSkillEntries` /
# `mkDevenvSkillEntries` (kiro/copilot HM + all devenv) guard on
# `builtins.isPath || builtins.isString`, then `builtins.readFileType == "directory"`.
# A raw derivation is NEITHER isPath NOR isString -> it trips the guard and is written
# AS TEXT into a single SKILL.md (the "lib.isPath trap"). The derivation's outPath is a
# STRING -> isString holds, readFileType (IFD-)resolves it to a directory, and every
# consumer (incl. upstream claude `mkSkillEntry` on modern home-manager) materializes the
# full tree recursively. A genuine `lib.isPath` value is unobtainable from generated
# content, so this skill requires a string-tolerant (modern) home-manager.
#
# The bake mirrors packages/kiro-cli/lib/autoMemory.nix: the Nix-resolved absolute base
# is interpolated into the builder, which substitutes the token.
{pkgs}: let
  traceSource = import ../../../lib/traceSource.nix {inherit (pkgs) lib;};
in
  {
    # Absolute XDG state base to bake, e.g. "${config.xdg.stateHome}/living-workflows" (HM),
    # or a standard XDG shell-default expression (devenv, which has no config.xdg.stateHome).
    stateBase,
    # The skill source directory as a `./` path literal (SKILL.md + references/).
    src,
  }: "${
    pkgs.runCommand "living-workflow-skill" {
      # Force devenv/direnv to track the skill source CONTENTS (see
      # lib/traceSource.nix). `cp -R ${src}` alone reads nothing inside the tree,
      # so a content edit would otherwise be served from a stale eval cache.
      srcFingerprint = traceSource.fingerprint src;
    } ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${pkgs.coreutils}/bin/mkdir -p "$out"
      ${pkgs.coreutils}/bin/cp -R ${src}/references "$out/references"
      ${pkgs.gnused}/bin/sed 's|@XDG_STATE_BASE@|${stateBase}|g' ${src}/SKILL.md > "$out/SKILL.md"
    ''
  }"
