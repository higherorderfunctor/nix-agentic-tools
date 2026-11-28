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
    # Read through the standalone settings merge so a loader that omits
    # Kagi's credentials option, or makes it mandatory, cannot pass.
    factory-loadServer-kagi-mcp-from-package-dir = mkTest "loadServer-kagi-mcp-from-package-dir" (
      (harness.mcpLib.evalSettings "kagi-mcp" {}).credentials == null
    );
  };
}
