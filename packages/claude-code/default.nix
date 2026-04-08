# Per-package barrel for claude-code.
#
# The binary derivation itself lives in overlays/claude-code.nix
# (not here — binaries are the flat-overlay exception to Bazel-style).
# This file exposes the non-binary facets: modules, fragments, docs,
# and factory-of-factory contribution to lib.ai.apps.mkClaude.
{
  docs = ./docs;
  fragments = ./fragments;

  lib.ai.apps.mkClaude = import ./lib/mkClaude.nix;

  modules = {
    devenv = ./modules/devenv;
    homeManager = ./modules/homeManager;
  };
}
