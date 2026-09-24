# The backend adapters, keyed by the backend name `mkBackendTransform` carries.
# A third backend is a new file here plus one attribute.
{
  lib,
  pkgs,
}: {
  devenv = import ./devenv.nix {inherit lib pkgs;};
  hm = import ./hm.nix {inherit lib pkgs;};
}
