# Per-package barrel for kiro-cli.
#
# The binary derivation itself lives in overlays/kiro-cli.nix
# (not here — binaries are the flat-overlay exception to Bazel-style).
# The darwin platform variant (kiro-cli-darwin) is an nvfetcher-only
# entry; the single kiro-cli package handles both platforms internally.
# This file exposes the non-binary facets: modules, fragments, docs,
# and factory-of-factory contribution to lib.ai.apps.mkKiro.
{
  docs = ./docs;
  fragments = ./fragments;

  lib.ai.apps.mkKiro = import ./lib/mkKiro.nix;

  modules = {
    devenv = ./modules/devenv;
    homeManager = ./modules/homeManager;
  };
}
