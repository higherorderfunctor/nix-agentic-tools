{extractedLib, ...}: {
  ai.apps.mkKimchi = import ./mkKimchi.nix {inherit extractedLib;};
}
