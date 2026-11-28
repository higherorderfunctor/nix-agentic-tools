# Drift gate for Semble's measured-once language and integration facts.
{
  extractedLib,
  pkgs,
  self,
  ...
}: {
  checks = (extractedLib {inherit pkgs;}).mkOwnerCheck {
    dir = ../extracted;
    name = "semble";
    package = self.ciPackages.${pkgs.stdenv.hostPlatform.system}.semble;
  };
}
