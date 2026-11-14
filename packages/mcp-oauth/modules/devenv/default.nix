{lib, ...}: {
  imports = [
    (import ../common.nix {
      backend = "devenv";
      installPackage = package: {packages = lib.mkBefore [(lib.hiPrio package)];};
      stateLocation = config: config.devenv.state;
    })
  ];
}
