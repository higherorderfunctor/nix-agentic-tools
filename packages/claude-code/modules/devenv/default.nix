# Applies the devenv transform to the claude-code app record.
{
  lib,
  pkgs,
  ...
} @ args: let
  aiLib = import ../../../../lib/ai {inherit lib;};
in
  (aiLib.app.devenvTransform (import ../../lib/mkClaude.nix {
    lib = lib // {ai = aiLib;};
    inherit pkgs;
  }))
  args
