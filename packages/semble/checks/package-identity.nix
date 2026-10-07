# Both Semble roles share the first-party build.
{
  lib,
  pkgs,
  self,
  ...
}: {
  checks.semble-package-identity = let
    inherit (pkgs.stdenv.hostPlatform) system;
    packages = self.ciPackages.${system};
  in
    assert lib.assertMsg (packages.semble.drvPath == packages.semble-mcp.drvPath)
    "semble and semble-mcp must share one derivation";
      pkgs.runCommand "semble-package-identity" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        echo 'Semble roles share one derivation' > "$out"
      '';
}
