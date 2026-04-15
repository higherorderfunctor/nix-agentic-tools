# Applies the HM transform to the kiro-cli app record.
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
} @ args:
(lib.ai.app.hmTransform (import ../../lib/mkKiro.nix {inherit lib pkgs;})) args
