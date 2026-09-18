# Distributable consumer source, assembled by the owner-local helper.
{pkgs, ...}:
import ../../lib/toolchainSource.nix {
  inherit pkgs;
  inherit (pkgs) lib;
}
