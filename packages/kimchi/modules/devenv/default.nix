# Applies the devenv transform to the kimchi app record.
{
  lib,
  pkgs,
  ...
} @ args: let
  aiLib = import ../../../../lib/ai {inherit lib;};
in
  (aiLib.app.devenvTransform (import ../../lib/mkKimchi.nix {
    lib = lib // {ai = aiLib;};
    inherit pkgs;
  }))
  args
