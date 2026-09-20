{lib}: let
  backendTransform = backend: import ./mkBackendTransform.nix {inherit lib backend;};
in {
  devenvTransform = backendTransform "devenv";
  hmTransform = backendTransform "hm";
  mkAiApp = import ./mkAiApp.nix {inherit lib;};
}
