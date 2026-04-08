# Instantiate `ourPkgs` from `inputs.nixpkgs` so every build input
# (python interpreter + python packages) routes through this repo's
# pinned nixpkgs instead of the consumer's. This is what gives the
# store path cache-hit parity against CI's standalone build — see
# dev/fragments/overlays/cache-hit-parity.md.
{inputs}: {
  nv-sources,
  stdenv,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
  inherit (ourPkgs) python314Packages;
  nv = nv-sources.mcp-server-fetch;
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
