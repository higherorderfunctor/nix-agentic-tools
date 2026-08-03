# Semble devenv integration. Options and cross-runtime contributions are shared
# byte-for-byte with Home Manager; only backend-native effects differ.
import ../common.nix {
  configureCodexCache = {
    config,
    lib,
  }: {
    ai.codex.settings._integration_writable_roots =
      lib.mkAfter [config.env.SEMBLE_CACHE_LOCATION];
    env.SEMBLE_CACHE_LOCATION = lib.mkDefault "${config.devenv.state}/semble-cache";
  };
  installPackage = package: {packages = [package];};
}
