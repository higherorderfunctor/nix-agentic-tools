final: let
  nv = final.nv-sources.mcp-server-git;
in
  final.python314Packages.buildPythonApplication {
    pname = "git-mcp";
    inherit (nv) version src;
    pyproject = true;
    build-system = with final.python314Packages; [hatchling];
    dependencies = with final.python314Packages; [click gitpython mcp pydantic];
    meta.mainProgram = "mcp-server-git";
    doCheck = false;
  }
