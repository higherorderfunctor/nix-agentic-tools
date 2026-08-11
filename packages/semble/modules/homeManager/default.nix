# Semble Home Manager integration. Options and cross-runtime contributions are
# shared byte-for-byte with devenv; only backend-native effects differ.
import ../common.nix {
  # semble's own default location, so nothing needs telling and no wrapper is
  # built — `relocatesCache` stays false. This value exists only so Codex can
  # be granted the writable root.
  cacheLocation = {config, ...}: "${config.xdg.cacheHome}/semble";
  installPackage = package: {home.packages = [package];};
}
