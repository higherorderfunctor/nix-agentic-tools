# sympy-mcp — SymPy MCP server.
#
# Wraps a Python environment with sympy + mcp dependencies.
# Uses mkDerivation (not writeShellApplication) so nix-update can
# find and manage the version + src attributes.
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) fetchFromGitHub makeWrapper python314;
  vu = import ../lib.nix;

  rev = "646c69558b622ab0e2814c58aa82143e56b76c33";
  src = fetchFromGitHub {
    owner = "sdiehl";
    repo = "sympy-mcp";
    inherit rev;
    hash = "sha256-AjRdiBtsF/ZpAUt+TPhvkT8VQ3y7rcJSogSSyQQXytI=";
  };

  pythonEnv =
    python314.withPackages (ps:
      with ps; [mcp typer python-dotenv sympy]);
in
  ourPkgs.stdenv.mkDerivation {
    pname = "sympy-mcp";
    version = vu.mkVersion {
      upstream = vu.readPyprojectVersion "${src}/pyproject.toml";
      inherit rev;
    };
    inherit src;
    dontBuild = true;
    nativeBuildInputs = [makeWrapper];
    doCheck = true;
    nativeCheckInputs = [python314.pkgs.pytest];
    checkPhase = ''
      runHook preCheck
      # Upstream pyproject.toml has python_files as string, not list (pytest >=9 requires list).
      # Override with -o to work around.
      ${pythonEnv}/bin/python -m pytest tests/ -v -o "python_files=test_*.py"
      runHook postCheck
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      makeWrapper ${pythonEnv}/bin/python $out/bin/sympy-mcp \
        --add-flags "-m mcp run $src/server.py"
      runHook postInstall
    '';
    doInstallCheck = true;
    installCheckPhase = vu.mkMcpSmokeTest {bin = "sympy-mcp";};
    passthru.mcpName = "sympy-mcp";
    meta.mainProgram = "sympy-mcp";
  }
