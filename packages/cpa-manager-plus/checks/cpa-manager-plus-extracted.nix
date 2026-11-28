# Compare a fresh measurement against the committed config.json and environment
# facts: a new native key or variable can be missing from the generated settings
# even while the old sample still loads. Reconciliation also catches a newly
# measured credential-shaped name with no annotation; drift alone would pass
# once the snapshot was refreshed.
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
