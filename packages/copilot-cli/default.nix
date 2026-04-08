# Per-package barrel for copilot-cli.
#
# The binary derivation itself lives in overlays/copilot-cli.nix
# (not here — binaries are the flat-overlay exception to Bazel-style).
# This file exposes the non-binary facets: modules, fragments, docs,
# and factory-of-factory contribution to lib.ai.apps.mkCopilot.
{
  docs = ./docs;
  fragments = ./fragments;

  lib.ai.apps.mkCopilot = import ./lib/mkCopilot.nix;

  modules = {
    devenv = ./modules/devenv;
    homeManager = ./modules/homeManager;
  };
}
