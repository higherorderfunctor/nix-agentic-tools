# Devenv backend transformer.
#
# Takes a backend-agnostic app record produced by `mkAiApp` and
# returns a devenv module function that writes the appropriate
# `files.*` / `claude.code.*` / `<ecosystem>.*` attributes for the
# devenv backend.
#
# The body is shared with `hmTransform.nix` — see
# `mkBackendTransform.nix`, of which this selects the `devenv` record
# key. The backend-specific emission (devenv's `files.*` rather than
# HM's `home.file.*`) lives in the per-app factory's `devenv.config`
# callback, not here.
{lib}:
import ./mkBackendTransform.nix {
  inherit lib;
  backend = "devenv";
}
