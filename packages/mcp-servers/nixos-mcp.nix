{inputs, ...}: final: let
  upstream = inputs.mcp-nixos.packages.${final.stdenv.hostPlatform.system}.default;
in
  upstream.overrideAttrs {passthru = (upstream.passthru or {}) // {mcpName = "nixos-mcp";};}
