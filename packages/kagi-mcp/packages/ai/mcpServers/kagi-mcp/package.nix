# kagi-mcp — builds the Kagi MCP server from GitHub source
# via buildPythonApplication.
{
  pkgs,
  packageLib,
  ...
}: let
  inherit (pkgs) fetchFromGitHub;
  # FastMCP 3 uses the MCP 1 API. Keep its whole Python scope on that major;
  # nixpkgs' default MCP now exposes the incompatible SDK 2 API.
  python313Packages = pkgs.python313Packages.overrideScope (_: prev: {
    mcp = prev.mcp_1;
  });
  vu = packageLib;

  rev = "59bbb8a545831afb4f4cd347c418af3d4bae6666";
  src = fetchFromGitHub {
    owner = "kagisearch";
    repo = "kagimcp";
    inherit rev;
    hash = "sha256-gfI0862pRbb31sLVMjeoFHmIjGA9kvfjVtUOe3WoH/c=";
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
    # Upstream pins `pydantic~=2.12.5`; the new nixpkgs ships pydantic 2.13.4,
    # which trips pythonRuntimeDepsCheckHook. Relax the pydantic bound — the
    # MCP-initialize smoke test in installCheckPhase still gates real runtime
    # compatibility with the newer point release.
    pythonRelaxDeps = ["pydantic"];
    doInstallCheck = true;
    installCheckPhase = vu.mkMcpSmokeTest {bin = "kagimcp";};
    meta.mainProgram = "kagimcp";
    doCheck = false;
  }
