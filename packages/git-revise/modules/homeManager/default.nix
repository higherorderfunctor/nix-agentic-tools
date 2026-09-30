# `git.revise.*` on Home Manager: user-global git configuration (../options.nix declares the tree).
#
# Picked up by native Home Manager module discovery in flake.nix.
{lib, ...}: {
  imports = [
    (import ../options.nix {
      inherit lib;
      backend = "homeManager";
    })
  ];
}
