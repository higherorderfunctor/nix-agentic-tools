# Applies the devenv transform to the chatgpt-codex app record.
{
  lib,
  pkgs,
  ...
} @ args: let
  aiLib = import ../../../../lib/ai {inherit lib;};
  # Keep this test seam out of the formal argument set. The module system
  # resolves every named function argument before calling the module, making a
  # `? builtins.getEnv` default unreachable when `_module.args.codexGetEnv` is
  # absent. `args` carries flattened `specialArgs`, so tests may override it
  # there deliberately; `_module.args` injection is intentionally unsupported.
  codexGetEnv = args.codexGetEnv or builtins.getEnv;
in
  (aiLib.app.devenvTransform (import ../../lib/mkCodex.nix {
    getEnv = codexGetEnv;
    lib = lib // {ai = aiLib;};
    inherit pkgs;
  }))
  args
