# sympy-mcp — SymPy MCP server.
#
# Wraps a Python environment with sympy + mcp dependencies.
# Uses mkDerivation (not writeShellApplication) so nix-update can
# find and manage the version + src attributes.
{
  pkgs,
  packageLib,
  ...
}: let
  inherit (pkgs) fetchFromGitHub makeWrapper python314;
  vu = packageLib;

  rev = "59ac6f9ae03e6b2eaa31676f45239ed8a5ad3975";
  src = fetchFromGitHub {
    owner = "sdiehl";
    repo = "sympy-mcp";
    inherit rev;
    hash = "sha256-w5qIgruGiZbJK3BCGselCRaoLdkktNmvJVzKa11Ul00=";
  };

  pythonEnv =
    python314.withPackages (ps:
      with ps; [mcp typer python-dotenv sympy]);
in
  pkgs.stdenv.mkDerivation {
    pname = "sympy-mcp";
    version = vu.mkVersion {
      # upstream: readPyprojectVersion @ pyproject.toml
      upstream = "0.1.0";
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
      # `python -m mcp run …` doesn't work because the `mcp` package
      # has no `__main__.py`. Use the `mcp` console script directly,
      # which is the canonical entry point provided by mcp[cli].
      makeWrapper ${pythonEnv}/bin/mcp $out/bin/sympy-mcp \
        --add-flags "run $src/server.py"
      runHook postInstall
    '';
    doInstallCheck = true;
    installCheckPhase = vu.mkMcpSmokeTest {bin = "sympy-mcp";};
    passthru.mcpName = "sympy-mcp";
    meta.mainProgram = "sympy-mcp";
  }
