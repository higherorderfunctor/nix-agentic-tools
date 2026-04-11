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
  version = "unstable-2026-03-18";
  src = fetchFromGitHub {
    owner = "sdiehl";
    repo = "sympy-mcp";
    rev = "646c69558b622ab0e2814c58aa82143e56b76c33";
    hash = "sha256-AjRdiBtsF/ZpAUt+TPhvkT8VQ3y7rcJSogSSyQQXytI=";
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
