# git-mcp — builds the MCP git server from the nvfetcher-tracked source
# via buildPythonApplication.
#
# Cannot override nixpkgs — mcp-server-git is not in this project's
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
    pname = "git-mcp";
    inherit (nv) version src;
    pyproject = true;
    build-system = with python314Packages; [hatchling];
    dependencies = with python314Packages; [click gitpython mcp pydantic];
    meta.mainProgram = "mcp-server-git";
    doCheck = false;
  }
