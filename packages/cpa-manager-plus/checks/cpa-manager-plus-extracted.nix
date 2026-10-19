# Drift and annotation reconciliation for the measured config.json and
# environment shape.
{
  extractedLib,
  lib,
  pkgs,
  self,
  ...
}: {
  checks = (extractedLib {inherit pkgs;}).mkOwnerCheck {
    dir = ../extracted;
    name = "cpa-manager-plus";
    package = self.ciPackages.${pkgs.stdenv.hostPlatform.system}.cpa-manager-plus;
    results = import ../extract/rules.nix {inherit lib;};
  };
}
