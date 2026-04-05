final: let
  nv = final.nv-sources.mcp-proxy;
  httpx-auth = final.python314Packages.httpx-auth.overridePythonAttrs {doCheck = false;};
in
  final.python314Packages.buildPythonApplication {
    pname = "mcp-proxy";
    inherit (nv) version src;
    pyproject = true;
    build-system = with final.python314Packages; [setuptools];
    dependencies = with final.python314Packages; [mcp uvicorn] ++ [httpx-auth];
    doCheck = false;
  }
