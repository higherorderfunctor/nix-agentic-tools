final: let
  nv = final.nv-sources.kagimcp;
  nv_kagiapi = final.nv-sources.kagiapi;
  kagiapi = final.python314Packages.buildPythonPackage {
    pname = "kagiapi";
    inherit (nv_kagiapi) version src;
    pyproject = true;
    build-system = with final.python314Packages; [setuptools];
    dependencies = with final.python314Packages; [requests typing-extensions];
    doCheck = false;
  };
in
  final.python314Packages.buildPythonApplication {
    pname = "kagi-mcp";
    inherit (nv) version src;
    pyproject = true;
    build-system = with final.python314Packages; [hatchling];
    dependencies = with final.python314Packages; [kagiapi mcp pydantic];
    meta.mainProgram = "kagimcp";
    doCheck = false;
  }
