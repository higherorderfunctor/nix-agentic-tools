# Semble Home Manager integration. Options and cross-runtime contributions are
# shared byte-for-byte with devenv; only the package installation sink differs.
import ../common.nix {
  installPackage = package: {home.packages = [package];};
}
