# HM backend transformer.
#
# Takes a backend-agnostic app record produced by `mkAiApp` and
# returns a home-manager module function that writes the appropriate
# `home.file.*` / `home.activation.*` / `programs.*` attributes for
# the HM backend.
#
# The body is shared with `devenvTransform.nix` — see
# `mkBackendTransform.nix`, of which this selects the `hm` record key.
# The backend-specific emission (`home.file.*` and friends) lives in
# the per-app factory's `hm.config` callback, not here.
{lib}:
import ./mkBackendTransform.nix {
  inherit lib;
  backend = "hm";
}
