# Applies the devenv transform to the copilot-cli app record.
# The result is a devenv module function the factory barrel
# (devenvModules.nix-agentic-tools) imports via collectFacet.
#
# Composition: devenvTransform takes the record and returns a module
# function `{config, ...}: <body>`. We immediately apply it to the
# same `args` so the wrapper file resolves to the module body
# attrset (matches the module-system contract for path-imported
# modules).
{
  lib,
  pkgs,
  ...
} @ args:
(lib.ai.app.devenvTransform (import ../../lib/mkCopilot.nix {inherit lib pkgs;})) args
