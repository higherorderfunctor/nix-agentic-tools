{
  lib,
  pkgs,
  ...
} @ args:
(import ../../lib/mkCopilot.nix {inherit lib pkgs;}) args
