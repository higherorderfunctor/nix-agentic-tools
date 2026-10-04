# Applies the devenv transform to the claude-code app record.
{
  config,
  lib,
  pkgs,
  ...
} @ args: let
  aiLib = import ../../../../lib/ai {inherit lib;};
in
  (aiLib.app.devenvTransform (import ../../lib/mkClaude.nix {
    lib = lib // {ai = aiLib;};
    # This flake's build unless the overlay is applied (ai.internal.packages).
    pkgs = pkgs // {ai = config.ai.internal.packages;};
  }))
  args
