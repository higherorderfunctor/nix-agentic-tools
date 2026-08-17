# HM backend transformer.
#
# Takes a backend-agnostic app record produced by `mkAiApp` and
# returns a home-manager module function that writes the appropriate
# `home.file.*` / `home.activation.*` / `programs.*` attributes for
# the HM backend.
#
# The body is shared with `devenvTransform.nix` — see
# `mkBackendTransform.nix`, of which this selects the `hm` record key.
# Static `ai.<runtime>.files` entries lower through the generic sink in the
# shared body. Runtime-specific lifecycle outputs (`home.activation.*`, native
# program options, mutable files) remain in each factory's `hm.config` callback.
{lib}:
import ./mkBackendTransform.nix {
  inherit lib;
  backend = "hm";
}
