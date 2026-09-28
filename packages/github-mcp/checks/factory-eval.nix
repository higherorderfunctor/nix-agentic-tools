# Factory contracts for this owner or shared primitive.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (import ../../../lib/testing/factory-harness.nix {inherit lib pkgs harness;}) mkTest;
in {
  checks = {
    # ── loadServer per-package relocation tests ─────────────────────
    factory-loadServer-github-mcp-from-package-dir = mkTest "loadServer-github-mcp-from-package-dir" (
      let
        mcpLib = import ../../../lib/mcp.nix {inherit lib;};
        serverDef = mcpLib.loadServer "github-mcp";
      in
        serverDef ? settingsOptions
        && serverDef.settingsOptions ? credentials
    );

    factory-github-mcp-has-package-module = mkTest "github-mcp-has-package-module" (
      builtins.pathExists ../modules/mcp-server.nix
    );
  };
}
