# `git.branchless.*` on Home Manager: user-global git configuration
# (../options.nix declares the tree). Home Manager cannot initialize
# repositories; the `enable` description says what to do instead.
#
# Picked up by native Home Manager module discovery in flake.nix.
{lib, ...}: let
  # A configured `test.jobs` never changes the strategy (only the `--jobs`
  # flag does), and the working-copy strategy runs one job at a time: every
  # `git test run` fails with a jobs value above 1 there. User-global is the
  # lowest layer this flake writes, so a null strategy here means upstream's
  # `working-copy` — the owner's lowest-scope checks, not a copy of them.
  assertions =
    ((import ../../lib/default.nix).git-branchless.settings {inherit lib;}).lowestScopeAssertions;
in {
  imports = [
    (import ../options.nix {
      inherit assertions lib;
      backend = "homeManager";
    })
  ];
}
