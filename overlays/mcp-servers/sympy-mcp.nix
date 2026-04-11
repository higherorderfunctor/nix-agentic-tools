# sympy-mcp — builds the SymPy MCP server with inline fetchFromGitHub source
# via writeShellApplication wrapping a python environment.
#
# Instantiates `ourPkgs` from `inputs.nixpkgs` so every build input
# (python interpreter + python packages + writeShellApplication) routes
# through this repo's pinned nixpkgs instead of the consumer's. This gives
# cache-hit parity against CI's standalone build (see
# dev/fragments/overlays/overlay-pattern.md).
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) fetchFromGitHub python314 writeShellApplication;
  vu = import ../version-utils.nix;

  rev = "646c69558b622ab0e2814c58aa82143e56b76c33";
  src = fetchFromGitHub {
    owner = "sdiehl";
    repo = "sympy-mcp";
    inherit rev;
    hash = "sha256-AjRdiBtsF/ZpAUt+TPhvkT8VQ3y7rcJSogSSyQQXytI=";
  };
  version = vu.mkVersion {
    upstream = vu.readPyprojectVersion "${src}/pyproject.toml";
    inherit rev;
  };
  python =
    python314.withPackages (ps:
      with ps; [mcp typer python-dotenv sympy]);
  drv = writeShellApplication {
    name = "sympy-mcp";
    runtimeInputs = [python];
    text = ''exec mcp run "${src}/server.py" "$@"'';
  };
in
  drv.overrideAttrs {
    inherit version;
    meta = (drv.meta or {}) // {mainProgram = "sympy-mcp";};
    passthru = (drv.passthru or {}) // {mcpName = "sympy-mcp";};
  }
