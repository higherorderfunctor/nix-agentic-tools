# Preserve the pinned external derivation across both Semble roles.
{
  inputs,
  lib,
  pkgs,
  self,
  ...
}: {
  checks.semble-package-identity = let
    inherit (pkgs.stdenv.hostPlatform) system;
    packages = self.ciPackages.${system};
    upstream = inputs.llm-agents.packages.${system}.semble;
  in
    assert lib.assertMsg (packages.semble.drvPath == packages.semble-mcp.drvPath)
    "semble and semble-mcp must share one derivation";
    assert lib.assertMsg (packages.semble.drvPath
      == upstream.drvPath
      && packages.semble.outPath == upstream.outPath)
    "semble must preserve the pinned llm-agents derivation and output";
      pkgs.runCommand "semble-package-identity" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        echo 'Semble roles preserve the pinned upstream identity' > "$out"
      '';
}
