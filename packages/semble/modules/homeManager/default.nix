# Semble Home Manager integration. Options and cross-runtime contributions are
# shared byte-for-byte with devenv; only backend-native effects differ.
import ../common.nix {
  # Force the HM-owned XDG location on every platform. Semble otherwise follows
  # platformdirs and uses ~/Library/Caches on Darwin, which would make the
  # activation guard clear a different cache than the installed package uses.
  cacheLocation = {config, ...}: "${config.xdg.cacheHome}/semble";
  installPackages = packages: {home.packages = packages;};
}
