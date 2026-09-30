# `git.settings` on Home Manager: an alias of `programs.git.settings`.
#
# Both backends expose the same `git.*` tree (packages/git/docs/git.md).
# Here the user-global delivery already exists, so `git.settings` is only a
# name for it: `mkAliasOptionModule` forwards every definition with its
# priority, and the git tool modules (git.branchless / git.absorb /
# git.revise) lower their typed settings into it, so they reach
# `programs.git.settings` — and conflict with a disagreeing raw value there —
# exactly as a hand-written value would.
#
# Home Manager renders `programs.git.settings` only while `programs.git.enable`
# is true. A `git.*` value set with it false would do nothing, so that case
# warns instead of passing silently.
#
# Picked up by native Home Manager module discovery in flake.nix.
{
  config,
  lib,
  options,
  ...
}: {
  imports = [(lib.mkAliasOptionModule ["git" "settings"] ["programs" "git" "settings"])];

  config.warnings =
    lib.optional
    (!config.programs.git.enable && lib.any (definition: definition != {}) options.git.settings.definitions)
    "git.* settings (git.settings, or a typed git.branchless / git.absorb / git.revise setting) are defined, but programs.git.enable is false, so Home Manager writes no git configuration and they have no effect. Set programs.git.enable = true.";
}
