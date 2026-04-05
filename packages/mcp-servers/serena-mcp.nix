{inputs, ...}: final: let
  upstream = inputs.serena.packages.${final.stdenv.hostPlatform.system}.default;
in
  upstream.overrideAttrs {
    passthru =
      (upstream.passthru or {})
      // {
        mcpArgs = ["start-mcp-server"];
        mcpName = "serena-mcp";
      };
  }
