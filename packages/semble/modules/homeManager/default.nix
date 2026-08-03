# Semble Home Manager integration. Options and cross-runtime contributions are
# shared byte-for-byte with devenv; only backend-native effects differ.
import ../common.nix {
  configureCodexCache = {
    config,
    lib,
  }: {
    ai.codex.settings._integration_writable_roots =
      lib.mkAfter ["${config.xdg.cacheHome}/semble"];
  };
  installPackage = package: {home.packages = [package];};
}
