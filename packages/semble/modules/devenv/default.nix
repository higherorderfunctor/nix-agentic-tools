# Semble devenv integration. Options and cross-runtime contributions are shared
# byte-for-byte with Home Manager; only the package installation sink differs.
import ../common.nix {
  installPackage = package: {packages = [package];};
}
