# Assemble the plain census tree consumed by the generator and its fixtures.
{
  dir,
  lib,
}: let
  inherit (import ../extracted/facts.nix {inherit lib;}) get load;
  inherit (load {inherit dir;}) aggregate;
in
  lib.mapAttrs (key: _: get aggregate key) aggregate
