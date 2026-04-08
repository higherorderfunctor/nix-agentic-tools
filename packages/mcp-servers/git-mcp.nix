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
  nv = nv-sources.mcp-server-git;
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
