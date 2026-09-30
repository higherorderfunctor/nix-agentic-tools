# `git.settings` on devenv: repository-local git configuration.
#
# devenv declares `git.root` and nothing else under `git`; this module adds
# `git.settings`, typed like Home Manager's `programs.git.settings`
# (lib/git-tool-settings/ini-type.nix) so one value evaluates the same on
# both backends. The git tool modules (git.branchless / git.absorb /
# git.revise) lower their typed settings into it.
#
# Delivery: `lib.generators.toGitINI` renders the merged attrset into a store
# file, and the `git:config` task (lib/git-tool-settings/repo-config.sh
# `include`) publishes it read-only in the common git directory and keeps its
# include.path the LAST entry of the common config. Every key it sets
# therefore beats user-global configuration, git-branchless's own
# branchless/config and hand edits; keys it does not set fall through. When
# the rendered attrset is empty the task removes the include instead.
#
# The task runs on every shell entry, after `git:branchless-init` when that
# exists (packages/git-branchless), because `git branchless init` appends its
# own include on a fresh repository. Outside a repository, with nothing to
# write, it does nothing.
#
# Picked up by native devenv module discovery in flake.nix.
{
  config,
  lib,
  pkgs,
  ...
}: let
  script = import ../../../../lib/git-tool-settings/repo-config.nix {inherit pkgs;};
  rendered = pkgs.writeText "nix-agentic-tools.gitconfig" (lib.generators.toGitINI config.git.settings);
in {
  options.git.settings = lib.mkOption {
    type = import ../../../../lib/git-tool-settings/ini-type.nix {inherit lib;};
    default = {};
    example = lib.literalExpression ''
      {
        merge.conflictStyle = "zdiff3";
        rebase.updateRefs = true;
      }
    '';
    description = ''
      Repository-local git configuration, the same attrset Home Manager's
      `programs.git.settings` takes (there `git.settings` is an alias of it).

      It is rendered with `lib.generators.toGitINI` and included from the
      common repository config, which every linked worktree reads. The include
      is kept as that config's last entry, so each key set here beats
      user-global configuration, git-branchless's `branchless/config` and
      hand edits (repaired on the next shell entry), while keys not set here
      fall through. A key cannot be unset from here: an empty string is a
      value. `config.worktree` (with `extensions.worktreeConfig`) still
      overrides it per worktree. git-branchless and git-absorb read this file
      but ignore `git -c` and `GIT_CONFIG_*`; configure them through files.

      Typed settings (`git.branchless.settings`, `git.absorb.settings`,
      `git.revise.settings`) are lowered into this attrset at the priority
      they are defined at, so an explicit typed value that disagrees with a
      value here is a definition conflict.
    '';
  };

  config.tasks."git:config" = {
    description = "Keep the nix-agentic-tools git configuration included last in the common repository config";
    before = ["devenv:enterShell"];
    exec = ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${lib.getExe script} include "$DEVENV_ROOT"${lib.optionalString (config.git.settings != {}) " ${rendered}"}
    '';
  };
}
