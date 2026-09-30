# `git.branchless.{enable,settings,scopedSync}`, declared once for both
# backends. The typed settings are generated from git-branchless's
# drift-checked sidecar (packages/git-branchless/extracted.json) by
# lib/git-tool-settings, whose factory lowers them into `git.settings`
# (packages/git). `scopedSync` is hand-declared: it is git's `alias.sync`,
# not a `branchless.*` key, so no census can produce it.
#
# The backend modules add what differs: devenv runs `git branchless init`,
# and the two backends check `test.jobs` against `test.strategy` differently
# (a repository-local null strategy may still be supplied user-global).
{
  backend,
  lib,
}: let
  settings = (import ../lib/default.nix).git-branchless.settings {inherit lib;};
  generated = settings.options.branchless;

  initScope = ''
    `git branchless init` is devenv-only by scope. On devenv, enabling this
    runs it on every shell entry for the repository at `DEVENV_ROOT`, before
    Git hooks are installed, passing `--main-branch` from
    `git.branchless.settings.core.mainBranch` when that is set (and otherwise
    the main branch the repository already recorded, so a re-run never
    replaces it with auto-detection). A repository whose HEAD has no commits
    yet, or whose primary repository is bare, is skipped with a notice.
    Home Manager is user-global and cannot initialize repositories: there,
    run `git branchless init` in each repository yourself.
  '';

  syncAlias = "branchless sync 'stack()'";
in
  {
    config,
    options,
    ...
  }: {
    imports = [
      (import ../../../lib/git-tool-settings/tool-module.nix {
        inherit backend settings;
        package = pkgs: pkgs.ai.gitTools.git-branchless;
        section = "branchless";
        tool = "git-branchless";
        enableDescription = ''
          Whether to enable git-branchless, installed from this flake's package.

          ${initScope}
        '';
        settingsOptions =
          lib.recursiveUpdate generated
          {
            core.mainBranch.description = ''
              ${generated.core.mainBranch.description}

              `git branchless init` writes this key into every repository it
              initializes (`.git/branchless/config`). A user-global value
              (Home Manager) therefore only matters in repositories where init
              has not run; a repository-local value (devenv) is included after
              init's file and wins.
            '';
          };
      })
    ];

    options.git.branchless.scopedSync = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Make bare `git sync` act on the current stack only, by setting git's
        `alias.sync = "${syncAlias}"`. No `branchless.*` key can do this:
        bare `git branchless sync` moves every draft stack, and a revset alias
        cannot shadow a builtin.

        What changes:
        - On the main branch, `git sync` does nothing (the stack is empty).
        - `git sync X` syncs `stack() | X`, not `X` alone. Sync everything with
          `git branchless sync`.
        - It still rebases onto the LOCAL main branch. From a linked worktree
          whose primary checkout holds main, that usually means nothing to do,
          and `git sync --pull` fails when `origin/main` has moved (main cannot
          be updated while another worktree has it checked out).

        `git branchless init` writes its own `alias.sync` into the repository.
        On devenv the repository-local include comes after it and wins. On Home
        Manager (user-global), init skips its alias only when the global one
        already exists: in a repository initialized before this was enabled,
        run `git branchless init` again.
      '';
    };

    # Lowered like a typed leaf: at the priority it is defined at.
    config.git.settings = lib.mkIf config.git.branchless.scopedSync {
      alias.sync = lib.mkOverride options.git.branchless.scopedSync.highestPrio syncAlias;
    };
  }
