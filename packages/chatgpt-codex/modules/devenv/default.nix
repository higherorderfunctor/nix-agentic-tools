# Applies the devenv transform to the chatgpt-codex app record.
{
  lib,
  pkgs,
  ...
} @ args: let
  aiLib = import ../../../../lib/ai {inherit lib;};
in
  (aiLib.app.devenvTransform (import ../../lib/mkCodex.nix {
    lib = lib // {ai = aiLib;};
    inherit pkgs;
  }))
  args
