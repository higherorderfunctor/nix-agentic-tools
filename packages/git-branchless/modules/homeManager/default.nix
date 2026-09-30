# `git.branchless.*` on Home Manager: user-global git configuration
# (../options.nix declares the tree). Home Manager cannot initialize
# repositories; the `enable` description says what to do instead.
#
# Picked up by native Home Manager module discovery in flake.nix.
{
  config,
  lib,
  ...
}: let
  test = config.git.branchless.settings.test;
in {
  imports = [
    (import ../options.nix {
      inherit lib;
      backend = "homeManager";
    })
  ];

  # A configured `test.jobs` never changes the strategy (only the `--jobs`
  # flag does), and the working-copy strategy runs one job at a time: every
  # `git test run` fails with a jobs value above 1 there. User-global is the
  # lowest layer NAT writes, so a null strategy here means upstream's
  # `working-copy`.
  config.assertions = [
    {
      assertion = test.jobs == null || test.jobs == 1 || test.strategy == "worktree";
      message = ''
        git.branchless.settings.test.jobs = ${toString test.jobs} needs git.branchless.settings.test.strategy = "worktree".
        git-branchless runs one job at a time with the working-copy strategy (its default), and a configured jobs value does not change the strategy, so every `git test run` would fail.
      '';
    }
  ];
}
