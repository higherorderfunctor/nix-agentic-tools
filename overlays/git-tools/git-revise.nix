# git-revise — override nixpkgs to pin a newer version.
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
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) fetchFromGitHub;
in
  ourPkgs.git-revise.overridePythonAttrs (old: {
    version = "unstable-2026-03-02";
    src = fetchFromGitHub {
      owner = "mystor";
      repo = "git-revise";
      rev = "a5bdbe420521a7784dd16c8f22b374b2f1d2d167";
      hash = "sha256-D3MicmtruCNiW/WI37y18XDXAl7J9oJdJnDY4Ohj+rE=";
    };
    pyproject = true;
    format = null;
    build-system = [ourPkgs.python3Packages.hatchling];
    # v0.8.0 added test_sshsign which needs openssh (not in nixpkgs' v0.7.0 check deps)
    nativeCheckInputs =
      (old.nativeCheckInputs or [])
      ++ [ourPkgs.openssh];
  })
