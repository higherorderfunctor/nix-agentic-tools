# Drift, cross-system facts and launcher flags are one gate.
{
  extractedLib,
  pkgs,
  self,
  ...
}: let
  package = self.ciPackages.${pkgs.stdenv.hostPlatform.system}.chatgpt-codex;
in {
  checks = (extractedLib {inherit pkgs;}).mkOwnerCheck {
    dir = ../extracted;
    name = "chatgpt-codex";
    inherit package;
    results = package.passthru.extractedRules.results;
  };
}
