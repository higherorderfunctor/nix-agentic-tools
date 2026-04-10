# fetch-mcp — builds the MCP fetch server from the nvfetcher-tracked source
# via buildPythonApplication.
#
# Cannot override nixpkgs — mcp-server-fetch is not in this project's
# pinned nixpkgs revision. Will convert once nixpkgs is bumped.
#
# Instantiates `ourPkgs` from `inputs.nixpkgs` for cache-hit parity
# (see dev/fragments/overlays/overlay-pattern.md).
{
  inputs,
  final,
  nv,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) python314Packages;
in
  python314Packages.buildPythonApplication {
    pname = "fetch-mcp";
    inherit (nv) version src;
    pyproject = true;
    build-system = with python314Packages; [hatchling];
    dependencies = with python314Packages; [
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
