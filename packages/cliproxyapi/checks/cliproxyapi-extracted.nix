# Drift and annotation reconciliation for the measured-once v8 config shape.
{
  extractedLib,
  lib,
  pkgs,
  self,
  ...
}: let
  configFacts = self.ciPackages.${pkgs.stdenv.hostPlatform.system}.cliproxyapi.passthru.extracted;
  vendorFacts = import ../extract/z-ai.nix {inherit pkgs;};
  extracted = pkgs.runCommand "cliproxyapi-extracted" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${pkgs.jq}/bin/jq --slurpfile vendor ${vendorFacts} '. + {zAi: $vendor[0]}' ${configFacts} > "$out"
  '';
in {
  checks = (extractedLib {inherit pkgs;}).mkOwnerCheck {
    dir = ../extracted;
    name = "cliproxyapi";
    extracted.${pkgs.stdenv.hostPlatform.system} = extracted;
    results = import ../extract/rules.nix {inherit lib;};
  };
}
