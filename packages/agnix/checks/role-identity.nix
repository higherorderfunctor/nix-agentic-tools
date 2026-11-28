# Role metadata must not trigger another Rust compile. Check the exported
# packages: cache parity can pass when both sides rebuild the same role.
{
  harness,
  pkgs,
  self,
  ...
}: {
  checks.agnix-role-identity = let
    base = packages.agnix.drvPath;
    packages = self.ciPackages.${pkgs.stdenv.hostPlatform.system};
  in
    assert harness.checkRows "Agnix role identity" {
      "agnix-lsp metadata must not fork the agnix derivation" = packages.agnix-lsp.drvPath == base;
      "agnix-mcp metadata must not fork the agnix derivation" = packages.agnix-mcp.drvPath == base;
    };
      pkgs.runCommand "agnix-role-identity" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        echo 'Agnix roles share one derivation' > "$out"
      '';
}
