{
  inputs,
  pkgs,
}:
(import ../../../../lib/packaging.nix {
  inherit (pkgs) lib;
  inherit inputs pkgs;
}).library
