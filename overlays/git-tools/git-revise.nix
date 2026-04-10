# git-revise — override nixpkgs to pin nvfetcher-tracked version.
#
# nixpkgs uses buildPythonPackage with format = "setuptools" for
# an older unstable commit. v0.8.0+ switched to pyproject.toml with
# hatchling, so we override src/version AND the build system via
# overridePythonAttrs (which re-evaluates format handling).
#
# Instantiates `ourPkgs` from `inputs.nixpkgs` for cache-hit parity
# (see dev/fragments/overlays/overlay-pattern.md).
{
  inputs,
  final,
  nv,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  # nvfetcher gives "v0.8.0"; nixpkgs expects "0.8.0"
  version = ourPkgs.lib.removePrefix "v" nv.version;
in
  ourPkgs.git-revise.overridePythonAttrs (old: {
    inherit version;
    inherit (nv) src;
    pyproject = true;
    format = null;
    build-system = [ourPkgs.python3Packages.hatchling];
    # v0.8.0 added test_sshsign which needs openssh (not in nixpkgs' v0.7.0 check deps)
    nativeCheckInputs =
      (old.nativeCheckInputs or [])
      ++ [ourPkgs.openssh];
  })
