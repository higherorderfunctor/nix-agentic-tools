import ../common.nix {
  backend = "hm";
  installPackage = package: {home.packages = [package];};
  stateLocation = config: config.xdg.stateHome;
}
