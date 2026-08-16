# Semble devenv integration. Options and cross-runtime contributions are shared
# byte-for-byte with Home Manager; only backend-native effects differ.
import ../common.nix {
  # devenv keeps the cache project-local rather than in the user's XDG cache,
  # so semble has to be told — delivered through the launcher wrapper, never
  # through devenv's `env` attrset, which would export it into the project
  # shell and hand it to the developer's own session too.
  cacheLocation = {config, ...}: "${config.devenv.state}/semble-cache";
  installCacheInvalidation = {
    cacheGuard,
    lib,
  }: {
    enterShell = ''
      ${lib.getExe cacheGuard}
    '';
  };
  installPackages = packages: {inherit packages;};
  relocatesCache = true;
}
