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
  nv = nv-sources.mcp-proxy;
  httpx-auth = python314Packages.httpx-auth.overridePythonAttrs {doCheck = false;};
in
  python314Packages.buildPythonApplication {
    pname = "mcp-proxy";
    inherit (nv) version src;
    pyproject = true;
    build-system = with python314Packages; [setuptools];
    dependencies = with python314Packages; [mcp uvicorn] ++ [httpx-auth];
    doCheck = false;
  }
