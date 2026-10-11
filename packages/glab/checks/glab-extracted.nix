# Drift gate for glab's measured-once config-key facts.
{
  extractedLib,
  pkgs,
  self,
  ...
}: {
  checks = (extractedLib {inherit pkgs;}).mkOwnerCheck {
    dir = ../extracted;
    name = "glab";
    package = self.ciPackages.${pkgs.stdenv.hostPlatform.system}.glab;
  };
}
