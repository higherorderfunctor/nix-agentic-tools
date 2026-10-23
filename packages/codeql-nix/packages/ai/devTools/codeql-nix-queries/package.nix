{pkgs}:
(import ../../../../lib/packaging.nix {
  inherit (pkgs) lib;
  inherit pkgs;
}).queries
