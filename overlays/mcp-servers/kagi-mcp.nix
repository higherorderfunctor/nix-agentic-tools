# kagi-mcp — builds the Kagi MCP server from GitHub source
# via buildPythonApplication. Includes an inline build of the kagiapi helper
# package (PyPI source).
#
# Instantiates `ourPkgs` from `inputs.nixpkgs` so every build input
# (python interpreter + python packages) routes through this repo's pinned
# nixpkgs instead of the consumer's. This gives cache-hit parity against
# CI's standalone build (see dev/fragments/overlays/overlay-pattern.md).
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) fetchFromGitHub fetchurl python314Packages;
  vu = import ../version-utils.nix;

  rev = "933e3384e9b1f34ebcc84b85310be7a6548900db";
  src = fetchFromGitHub {
    owner = "kagisearch";
    repo = "kagimcp";
    inherit rev;
    hash = "sha256-jTxmn6H0SPV/vwDW+4tQiTXceVJZwwVgLXsF9bjSPS8=";
  };

  kagiapi = python314Packages.buildPythonPackage {
    pname = "kagiapi";
    version = "0.2.1";
    src = fetchurl {
      url = "https://pypi.org/packages/source/k/kagiapi/kagiapi-0.2.1.tar.gz";
      hash = "sha256-NV/kB7TGg9bwhIJ+T4VP2VE03yhC8V0Inaz/Yg4/Sus=";
    };
    pyproject = true;
    build-system = with python314Packages; [setuptools];
    dependencies = with python314Packages; [requests typing-extensions];
    doCheck = false;
  };
in
  python314Packages.buildPythonApplication {
    pname = "kagi-mcp";
    version = vu.mkVersion {
      upstream = vu.readPyprojectVersion "${src}/pyproject.toml";
      inherit rev;
    };
    inherit src;
    pyproject = true;
    build-system = with python314Packages; [hatchling];
    dependencies = with python314Packages; [kagiapi mcp pydantic];
    meta.mainProgram = "kagimcp";
    doCheck = false;
  }
