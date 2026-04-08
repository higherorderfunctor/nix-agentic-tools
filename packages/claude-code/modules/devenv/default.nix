# Devenv and HM share the same factory call for now.
{
  lib,
  pkgs,
  ...
} @ args:
(import ../../lib/mkClaude.nix {inherit lib pkgs;}) args
