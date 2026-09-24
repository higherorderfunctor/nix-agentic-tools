# Applies the HM transform to the kimchi app record, alongside the shared
# (backend-independent) kimchi modules.
# The result is a home-manager module the factory barrel
# (homeManagerModules.default) imports via native owner discovery.
#
# Composition: hmTransform takes the record and returns a module function
# `{config, ...}: <body>`; the module system applies it, so it can be listed in
# `imports` directly.
{
  lib,
  pkgs,
  ...
}: let
  extLib = lib.extend (_: prev: {
    ai = import ../../../../lib/ai {lib = extLib;};
    hm = prev.hm or {dag = import ../../../../lib/hm-dag.nix {lib = extLib;};};
  });
in {
  imports = [
    ../common.nix
    (extLib.ai.app.hmTransform (import ../../lib/mkKimchi.nix {
      lib = extLib;
      inherit pkgs;
    }))
  ];
}
