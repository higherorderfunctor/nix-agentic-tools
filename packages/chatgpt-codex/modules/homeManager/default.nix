# Applies the Home Manager transform to the chatgpt-codex app record.
{
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
    inherit pkgs;
  }))
  args
