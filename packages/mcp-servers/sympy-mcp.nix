# Instantiate `ourPkgs` from `inputs.nixpkgs` so every build input
# (python interpreter + python packages + writeShellApplication)
# routes through this repo's pinned nixpkgs instead of the
# consumer's. This is what gives the store path cache-hit parity
# against CI's standalone build — see
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
  inherit (ourPkgs) python314 writeShellApplication;
  nv = nv-sources.sympy-mcp;
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
