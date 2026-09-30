# `git.branchless.*` on devenv: repository-local git configuration
# (../options.nix declares the tree), plus `git branchless init`.
#
# `git:branchless-init` runs lib/git-tool-settings/repo-config.sh `init` on
# every shell entry while `git.branchless.enable` is true: before
# `git:config` (packages/git), because a first init appends its own include
# and NAT's must end up after it, and before devenv installs Git hooks, so
# git-branchless owns its hooks before prek installs or chains its own. There
# is no "already initialized" guard: init is idempotent, and the directory a
# guard would test for exists after a failed init or after any earlier
# branchless command.
#
# A failing devenv task does not stop shell entry (measured, devenv 2.4.1):
# devenv reports it and enters the shell, but every task ordered after it is
# skipped as "dependency failed" for that entry — `git:config` and prek's hook
# installation included. The next entry retries.
#
# Picked up by native devenv module discovery in flake.nix.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.git.branchless;
  inherit (cfg.settings) test;
  script = import ../../../../lib/git-tool-settings/repo-config.nix {inherit pkgs;};
  gitHooksEnabled = lib.attrByPath ["git-hooks" "enable"] false config;
in {
  imports = [
    (import ../options.nix {
      inherit lib;
      backend = "devenv";
    })
  ];

  config = lib.mkMerge [
    {
      # A configured `test.jobs` never changes the strategy (only the
      # `--jobs` flag does), and the working-copy strategy runs one job at a
      # time. Repository-local: a null strategy may still come user-global,
      # so that case only warns.
      assertions = [
        {
          assertion = !(test.jobs != null && test.jobs != 1 && test.strategy == "working-copy");
          message = ''
            git.branchless.settings.test.jobs = ${toString test.jobs} contradicts git.branchless.settings.test.strategy = "working-copy".
            git-branchless runs one job at a time with the working-copy strategy, and a configured jobs value does not change the strategy, so every `git test run` would fail. Set test.strategy = "worktree".
          '';
        }
      ];
      warnings = lib.optional (test.jobs != null && test.jobs != 1 && test.strategy == null) ''
        git.branchless.settings.test.jobs = ${toString test.jobs} with git.branchless.settings.test.strategy unset: every `git test run` in this repository fails unless the user-global configuration sets branchless.test.strategy = "worktree". Set it here to make the repository self-contained.
      '';
    }

    (lib.mkIf cfg.enable {
      tasks = {
        "git:branchless-init" = {
          description = "Initialize git-branchless before devenv installs Git hooks";
          before = ["devenv:enterShell" "git:config"] ++ lib.optional gitHooksEnabled "devenv:git-hooks:install";
          exec = ''
            set -euETo pipefail
            shopt -s inherit_errexit 2>/dev/null || :
            ${lib.getExe script} init "$DEVENV_ROOT" ${lib.getExe pkgs.ai.gitTools.git-branchless}${lib.optionalString (cfg.settings.core.mainBranch != null) " ${lib.escapeShellArg cfg.settings.core.mainBranch}"}
          '';
        };
      };
    })
  ];
}
