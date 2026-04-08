{lib}: {
  mkAiApp = import ./mkAiApp.nix {inherit lib;};
  hmTransform = import ./hmTransform.nix {inherit lib;};
  devenvTransform = import ./devenvTransform.nix {inherit lib;};
}
