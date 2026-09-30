# `git.revise.*` on devenv: repository-local git configuration (../options.nix declares the tree).
#
# Picked up by native devenv module discovery in flake.nix.
{lib, ...}: {
  imports = [
    (import ../options.nix {
      inherit lib;
      backend = "devenv";
    })
  ];
}
