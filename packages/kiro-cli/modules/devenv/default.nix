# Applies the devenv transform to the kiro-cli app record.
{
  lib,
  pkgs,
  ...
} @ args: let
  aiLib = import ../../../../lib/ai {inherit lib;};
in
  (aiLib.app.devenvTransform (import ../../lib/mkKiro.nix {
    lib = lib // {ai = aiLib;};
    inherit pkgs;
  }))
  args
