# Applies the devenv transform to the copilot-cli app record.
{
  lib,
  pkgs,
  ...
} @ args: let
  aiLib = import ../../../../lib/ai {inherit lib;};
in
  (aiLib.app.devenvTransform (import ../../lib/mkCopilot.nix {
    lib = lib // {ai = aiLib;};
    inherit pkgs;
  }))
  args
