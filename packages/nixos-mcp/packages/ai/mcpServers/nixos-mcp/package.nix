# nixos-mcp — builds the upstream mcp-nixos package via its exposed
# `lib.mkMcpNixos`, against the supplied package set.
#
# The upstream factory scopes its FastMCP 4 extension to this application.
# Pass a package set whose MCP pair can be inspected without following the
# extension's own final `mcp` back into its version-selection condition.
{
  inputs,
  pkgs,
  packageLib,
  ...
}: let
  python3Packages = pkgs.python3Packages.overrideScope (_: prev: {
    # nixpkgs' mcp-types inherits version/src from its mcp argument. Bind that
    # argument to the unextended SDK before upstream inspects both versions.
    mcp-types = prev.mcp-types.override {inherit (prev) mcp;};
  });
  upstream = inputs.mcp-nixos.lib.mkMcpNixos {inherit pkgs python3Packages;};
  vu = packageLib;
in
  upstream.overrideAttrs {
    passthru = (upstream.passthru or {}) // {mcpName = "nixos-mcp";};
    doInstallCheck = true;
    installCheckPhase = vu.mkMcpSmokeTest {bin = "mcp-nixos";};
  }
