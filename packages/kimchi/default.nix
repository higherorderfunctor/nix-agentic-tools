# Per-package barrel for kimchi.
#
# The binary derivation itself lives in overlays/kimchi.nix
# (not here — binaries are the flat-overlay exception to Bazel-style).
# This file exposes the non-binary facets: modules, fragments, docs,
# and factory-of-factory contribution to lib.ai.apps.mkKimchi.
{
  docs = ./docs;
  fragments = ./fragments;

  lib.ai.apps.mkKimchi = import ./lib/mkKimchi.nix;

  modules = {
    devenv = ./modules/devenv;
    homeManager = ./modules/homeManager;
  };
}
