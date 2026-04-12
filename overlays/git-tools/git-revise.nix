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
  vu = import ../lib.nix;

  rev = "646c69558b622ab0e2814c58aa82143e56b76c33";
  src = fetchFromGitHub {
    owner = "mystor";
    repo = "git-revise";
    inherit rev;
    hash = "sha256-D3MicmtruCNiW/WI37y18XDXAl7J9oJdJnDY4Ohj+rE=";
  };
in
  ourPkgs.git-revise.overridePythonAttrs (old: {
    version = vu.mkVersion {
      # pyproject.toml uses dynamic version (hatch); read from __init__.py
      upstream = vu.readPythonDunderVersion "${src}/gitrevise/__init__.py";
      inherit rev;
    };
    inherit src;
    pyproject = true;
    format = null;
    build-system = [ourPkgs.python3Packages.hatchling];
    # v0.8.0 added test_sshsign which needs openssh (not in nixpkgs' v0.7.0 check deps)
    nativeCheckInputs =
      (old.nativeCheckInputs or [])
      ++ [ourPkgs.openssh];
  })
