# Applies the Home Manager transform to the chatgpt-codex app record.
# The result is a home-manager module function the factory barrel
# (homeManagerModules.default) imports via native owner discovery.
#
# Composition: hmTransform takes the record and returns a module function
# `{config, ...}: <body>`. Applying it to `args` here resolves the wrapper to
# the module body attrset expected by the module system.
{
  config,
  lib,
  pkgs,
  ...
} @ args: let
  extLib = lib.extend (_: prev: {
    ai = import ../../../../lib/ai {lib = extLib;};
    hm = prev.hm or {dag = import ../../../../lib/hm-dag.nix {lib = extLib;};};
  });
in
  (extLib.ai.app.hmTransform (import ../../lib/mkCodex.nix {
    lib = extLib;
    # This flake's build unless the overlay is applied (ai.internal.packages).
    pkgs = pkgs // {ai = config.ai.internal.packages;};
  }))
  args
