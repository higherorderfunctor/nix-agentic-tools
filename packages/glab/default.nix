# Per-package barrel for glab.
#
# The binary derivation lives in overlays/dev-tools/glab.nix — binaries are
# the flat-overlay exception to the Bazel-style barrel. This file exposes
# the non-binary facets: the two module facets and the wrapper factory.
{
  docs = ./docs;

  lib.glab.mkGlab = import ./lib/mkGlab.nix;

  modules = {
    devenv = ./modules/devenv;
    homeManager = ./modules/homeManager;
  };
}
