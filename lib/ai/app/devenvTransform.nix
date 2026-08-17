# Devenv backend transformer.
#
# Takes a backend-agnostic app record produced by `mkAiApp` and
# returns a devenv module function that writes the appropriate
# `files.*` / `claude.code.*` / `<ecosystem>.*` attributes for the
# devenv backend.
#
# The body is shared with `hmTransform.nix` — see
# `mkBackendTransform.nix`, of which this selects the `devenv` record
# key. Static `ai.<runtime>.files` entries lower through the generic sink in
# the shared body. Runtime-specific lifecycle outputs (tasks, native program
# options, mutable files) remain in each factory's `devenv.config` callback.
{lib}:
import ./mkBackendTransform.nix {
  inherit lib;
  backend = "devenv";
}
