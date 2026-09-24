{lib}: let
  # Both backends share one body; `backend` selects which record key carries
  # the backend spec and which native sinks the adapter lowers into.
  backendTransform = backend: import ./mkBackendTransform.nix {inherit lib backend;};
in {
  devenvTransform = backendTransform "devenv";
  hmTransform = backendTransform "hm";
  mkRuntime = import ./mkRuntime.nix {inherit lib;};
}
