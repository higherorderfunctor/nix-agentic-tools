# sympy-mcp — builds the SymPy MCP server from the nvfetcher-tracked source
# via writeShellApplication wrapping a python environment.
#
# Instantiates `ourPkgs` from `inputs.nixpkgs` so every build input
# (python interpreter + python packages + writeShellApplication) routes
# through this repo's pinned nixpkgs instead of the consumer's. This gives
# cache-hit parity against CI's standalone build (see
# dev/fragments/overlays/overlay-pattern.md).
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
  inherit (ourPkgs) python314 writeShellApplication;
  python =
    python314.withPackages (ps:
      with ps; [mcp typer python-dotenv sympy]);
  drv = writeShellApplication {
    name = "sympy-mcp";
    runtimeInputs = [python];
    text = ''exec mcp run "${nv.src}/server.py" "$@"'';
  };
in
  drv.overrideAttrs {passthru = (drv.passthru or {}) // {mcpName = "sympy-mcp";};}
