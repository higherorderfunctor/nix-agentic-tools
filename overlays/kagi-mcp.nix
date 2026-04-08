# kagi-mcp — builds the Kagi MCP server from the nvfetcher-tracked source
# via buildPythonApplication. Includes an inline build of the kagiapi helper
# package (also nvfetcher-tracked under the "kagiapi" key).
#
# Instantiates `ourPkgs` from `inputs.nixpkgs` so every build input
# (python interpreter + python packages) routes through this repo's pinned
# nixpkgs instead of the consumer's. This gives cache-hit parity against
# CI's standalone build (see dev/fragments/overlays/overlay-pattern.md).
#
# Argument shape adapted from legacy curried pattern during Milestone 5 port.
# `nv` is the merged kagimcp entry; `nv_kagiapi` is read directly from
# final.nv-sources for the companion kagiapi package.
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
  nv_kagiapi = final.nv-sources.kagiapi;
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
