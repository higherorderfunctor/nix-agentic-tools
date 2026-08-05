# Applies the devenv transform to the chatgpt-codex app record.
{
  lib,
  pkgs,
  ...
} @ args: let
  aiLib = import ../../../../lib/ai {inherit lib;};
  codexGetEnv = args.codexGetEnv or builtins.getEnv;
in
  (aiLib.app.devenvTransform (import ../../lib/mkCodex.nix {
    getEnv = codexGetEnv;
    lib = lib // {ai = aiLib;};
    inherit pkgs;
  }))
  args
