# fetch-mcp — builds the MCP fetch server from the nvfetcher-tracked source
# via buildPythonApplication.
#
# Instantiates `ourPkgs` from `inputs.nixpkgs` so every build input
# (python interpreter + python packages) routes through this repo's pinned
# nixpkgs instead of the consumer's. This gives cache-hit parity against
# CI's standalone build (see dev/fragments/overlays/overlay-pattern.md).
#
# Argument shape adapted from legacy curried pattern during Milestone 5 port.
{
  inputs,
  final,
  nv,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
    config.allowUnfree = true;
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
