# Applies the HM transform to the claude-code app record.
# The result is a home-manager module function the factory barrel
# (homeManagerModules.default) imports via collectFacet.
#
# Composition: hmTransform takes the record and returns a module
# function `{config, ...}: <body>`. We immediately apply it to the
# same `args` so the wrapper file resolves to the module body
# attrset (matches the module-system contract for path-imported
# modules).
{
  lib,
  pkgs,
  ...
} @ args: let
  extLib = lib.extend (_: _: {ai = import ../../../../lib/ai {lib = extLib;};});
in
  (extLib.ai.app.hmTransform (import ../../lib/mkClaude.nix {
    lib = extLib;
    inherit pkgs;
  }))
  args
