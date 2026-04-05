final: let
  nv = final.nv-sources.sympy-mcp;
  python =
    final.python314.withPackages (ps:
      with ps; [mcp typer python-dotenv sympy]);
  drv = final.writeShellApplication {
    name = "sympy-mcp";
    runtimeInputs = [python];
    text = ''exec mcp run "${nv.src}/server.py" "$@"'';
  };
in
  drv.overrideAttrs {passthru = (drv.passthru or {}) // {mcpName = "sympy-mcp";};}
