# Applies the devenv transform to the kimchi app record, alongside the shared
# (backend-independent) kimchi modules.
{
  lib,
  pkgs,
  ...
}: let
  aiLib = import ../../../../lib/ai {inherit lib;};
in {
  imports = [
    ../common.nix
    (aiLib.app.devenvTransform (import ../../lib/mkKimchi.nix {
      lib = lib // {ai = aiLib;};
      inherit pkgs;
    }))
  ];
}
