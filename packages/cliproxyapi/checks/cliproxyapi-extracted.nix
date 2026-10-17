# Drift and annotation reconciliation for the measured-once v8 config shape.
{
  extractedLib,
  lib,
  pkgs,
  self,
  ...
}: {
  checks = (extractedLib {inherit pkgs;}).mkOwnerCheck {
    dir = ../extracted;
    name = "cliproxyapi";
    package = self.ciPackages.${pkgs.stdenv.hostPlatform.system}.cliproxyapi;
    results = import ../extract/rules.nix {inherit lib;};
  };
}
