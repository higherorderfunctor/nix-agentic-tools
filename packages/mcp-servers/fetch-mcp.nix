final: let
  nv = final.nv-sources.mcp-server-fetch;
in
  final.python314Packages.buildPythonApplication {
    pname = "fetch-mcp";
    inherit (nv) version src;
    pyproject = true;
    build-system = with final.python314Packages; [hatchling];
    dependencies = with final.python314Packages; [
      httpx
      markdownify
      mcp
      protego
      pydantic
      readabilipy
      requests
    ];
    postPatch = ''
      substituteInPlace src/mcp_server_fetch/server.py \
        --replace-fail 'AsyncClient(proxies=' 'AsyncClient(proxy='
    '';
    pythonRelaxDeps = ["httpx"];
    meta.mainProgram = "mcp-server-fetch";
    doCheck = false;
  }
