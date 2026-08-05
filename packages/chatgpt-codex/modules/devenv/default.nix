# Applies the devenv transform to the chatgpt-codex app record.
{
  codexGetEnv ? builtins.getEnv,
  lib,
  pkgs,
  ...
} @ args: let
  aiLib = import ../../../../lib/ai {inherit lib;};
in
  (aiLib.app.devenvTransform (import ../../lib/mkCodex.nix {
    getEnv = codexGetEnv;
    lib = lib // {ai = aiLib;};
    inherit pkgs;
  }))
  args
