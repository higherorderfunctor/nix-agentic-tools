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

    # Resolve the package module through the standalone settings merge so a
    # caller that omits credentials does not need a credential reference.
    factory-loadServer-github-mcp-from-package-dir = mkTest "loadServer-github-mcp-from-package-dir" (
      (harness.mcpLib.evalSettings "github-mcp" {}).credentials == null
    );
  };
}
