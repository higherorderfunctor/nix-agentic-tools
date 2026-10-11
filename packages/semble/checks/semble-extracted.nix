# Drift gate for Semble's measured-once language and integration facts.
{
  extractedLib,
  lib,
  pkgs,
  self,
  ...
}: {
  checks = assert lib.assertMsg ((import ../lib/extracted.nix {inherit lib;}).parsedLanguages != []) "packages/semble/lib/extracted.nix derives no parsed languages";
    (extractedLib {inherit pkgs;}).mkOwnerCheck {
      dir = ../extracted;
      name = "semble";
      package = self.ciPackages.${pkgs.stdenv.hostPlatform.system}.semble;
    };
}
