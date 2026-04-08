{
  lib,
  pkgs,
  ...
} @ args:
(import ../../lib/mkClaude.nix {inherit lib pkgs;}) args
