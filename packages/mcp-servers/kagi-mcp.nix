# Instantiate `ourPkgs` from `inputs.nixpkgs` so every build input
# (python interpreter + python packages, including the inline
# kagiapi helper) routes through this repo's pinned nixpkgs instead
# of the consumer's. This is what gives the store path cache-hit
# parity against CI's standalone build — see
# dev/fragments/overlays/overlay-pattern.md.
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
  nv = nv-sources.kagimcp;
  nv_kagiapi = nv-sources.kagiapi;
  kagiapi = python314Packages.buildPythonPackage {
    pname = "kagiapi";
    inherit (nv_kagiapi) version src;
    pyproject = true;
    build-system = with python314Packages; [setuptools];
    dependencies = with python314Packages; [requests typing-extensions];
    doCheck = false;
  };
in
  python314Packages.buildPythonApplication {
    pname = "kagi-mcp";
    inherit (nv) version src;
    pyproject = true;
    build-system = with python314Packages; [hatchling];
    dependencies = with python314Packages; [kagiapi mcp pydantic];
    meta.mainProgram = "kagimcp";
    doCheck = false;
  }
