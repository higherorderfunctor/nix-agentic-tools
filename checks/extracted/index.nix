{
  lib,
  pkgs,
  ...
}: let
  inherit (import ../../lib/extracted {inherit pkgs;}) index load;
  owners = import ./owners.nix;
in {
  checks.extracted-index = index (lib.mapAttrs (_: dir: load {inherit dir;}) owners);
}
