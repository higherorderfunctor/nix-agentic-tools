# Per-package barrel for the Beads devenv lifecycle.
{
  docs = ./docs;

  lib.beads.mkLifecycle = import ./lib/mkLifecycle.nix;

  modules.devenv = ./modules/devenv;
}
