# Role metadata must not trigger another Rust compile.
{
  lib,
  pkgs,
  self,
  ...
}: {
  checks.agnix-role-identity = let
    packages = self.packages.${pkgs.stdenv.hostPlatform.system};
  in
    assert lib.assertMsg (packages.agnix.drvPath
      == packages.agnix-lsp.drvPath
      && packages.agnix.drvPath == packages.agnix-mcp.drvPath)
    "agnix, agnix-lsp and agnix-mcp must share one derivation";
      pkgs.runCommand "agnix-role-identity" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        echo 'Agnix roles share one derivation' > "$out"
      '';
}
