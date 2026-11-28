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
    factory-github-mcp-has-package-module = mkTest "github-mcp-has-package-module" (
      builtins.pathExists ../modules/mcp-server.nix
    );

    # The service submodule reads settingsOptions directly; the standalone
    # merge also lets callers omit the credential reference.
    factory-loadServer-github-mcp-from-package-dir = mkTest "loadServer-github-mcp-from-package-dir" (
      let
        serverDef = harness.mcpLib.loadServer "github-mcp";
      in
        serverDef.settingsOptions ? credentials
        && (harness.mcpLib.evalSettings "github-mcp" {}).credentials == null
    );
  };
}
