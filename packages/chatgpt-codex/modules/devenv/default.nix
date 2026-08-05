# Applies the devenv transform to the chatgpt-codex app record.
{
  lib,
  pkgs,
  ...
} @ args: let
  aiLib = import ../../../../lib/ai {inherit lib;};
  # Keep this test seam out of the formal argument set. The module system
  # binds an attribute for every name in `functionArgs`, so a `? builtins.getEnv`
  # default is never consulted; forcing it queries `_module.args.codexGetEnv`,
  # absent in production. `args` carries flattened `specialArgs`, so tests
  # override it there. `_module.args` injection is unsupported and silently
  # falls back to `builtins.getEnv` rather than erroring.
  codexGetEnv = args.codexGetEnv or builtins.getEnv;
in
  (aiLib.app.devenvTransform (import ../../lib/mkCodex.nix {
    getEnv = codexGetEnv;
    lib = lib // {ai = aiLib;};
    inherit pkgs;
  }))
  args
