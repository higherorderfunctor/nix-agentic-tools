# Applies the devenv transform to the kiro-cli app record.
{
  config,
  lib,
  pkgs,
  ...
} @ args: let
  aiLib = import ../../../../lib/ai {inherit lib;};
in
  (aiLib.app.devenvTransform (import ../../lib/mkKiro.nix {
    lib = lib // {ai = aiLib;};
    # This flake's build unless the overlay is applied (ai.internal.packages).
    pkgs = pkgs // {ai = config.ai.internal.packages;};
  }))
  args
