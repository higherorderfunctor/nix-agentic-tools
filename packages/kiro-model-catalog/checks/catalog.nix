{
  extractedLib,
  pkgs,
  self,
  ...
}: let
  inherit (pkgs.stdenv.hostPlatform) system;
  package = self.ciPackages.${system}.kiro-model-catalog;
in {
  checks =
    {
      kiro-models-fixtures = pkgs.runCommand "kiro-models-fixtures" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        ${pkgs.python3}/bin/python3 ${./models.py} \
          ${../extract/models.py} ${package.src}
        ${pkgs.python3}/bin/python3 ${./update.py} \
          ${../extract} ${../packages/docs/kiro-model-catalog/package.nix} ${package.src}
        touch "$out"
      '';
    }
    // (extractedLib {inherit pkgs;}).mkOwnerCheck {
      dir = ../extracted;
      name = "kiro-model-catalog";
      needs = [
        {
          key = "models";
          contains = "auto";
        }
      ];
      inherit package;
    };
}
