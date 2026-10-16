{lib}: let
  # Both backends share one body; `backend` selects which record key carries
  # the backend spec and which backend the transform targets. ai-module lowers
  # the result.
  backendTransform = backend: import ./mkBackendTransform.nix {inherit lib backend;};
in {
  devenvTransform = backendTransform "devenv";
  hmTransform = backendTransform "hm";
  mkRuntime = import ./mkRuntime.nix {inherit lib;};
}
