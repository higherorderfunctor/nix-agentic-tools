{
  lib,
  pkgs,
  ...
} @ args:
(import ../../lib/mkKiro.nix {inherit lib pkgs;}) args
