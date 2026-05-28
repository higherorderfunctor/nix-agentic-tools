# kagi-mcp — builds the Kagi MCP server from GitHub source
# via buildPythonApplication.
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
  inherit (ourPkgs) fetchFromGitHub python313Packages;
  vu = import ../lib.nix;

  rev = "7261eac2d3bfa41ce23928628ab84435da091acb";
  src = fetchFromGitHub {
    owner = "kagisearch";
    repo = "kagimcp";
    inherit rev;
    hash = "sha256-Pnx4riqIFLzJJY2P0VAEl6GBYjJo6gGWbt7gbLmOqmo=";
  };
in
  python313Packages.buildPythonApplication {
    pname = "kagi-mcp";
    version = vu.mkVersion {
      upstream = vu.readPyprojectVersion "${src}/pyproject.toml";
      inherit rev;
    };
    inherit src;
    pyproject = true;
    build-system = with python313Packages; [hatchling];
    dependencies = with python313Packages; [fastmcp pydantic python-dateutil typing-extensions urllib3];
    doInstallCheck = true;
    installCheckPhase = vu.mkMcpSmokeTest {bin = "kagimcp";};
    meta.mainProgram = "kagimcp";
    doCheck = false;
  }
