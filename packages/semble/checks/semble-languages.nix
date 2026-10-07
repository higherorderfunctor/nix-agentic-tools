# Drift gate for packages/semble/extracted.json, Semble's language knowledge:
# the grammars semble-grammars bundles, the extension map, and the
# language sets behind each content type.
#
# The grouped package updater regenerates the snapshot from passthru.extracted.
{
  extractedLib,
  lib,
  pkgs,
  self,
  ...
}: {
  checks = let
    inherit (pkgs.stdenv.hostPlatform) system;
    inherit (extractedLib {inherit pkgs;}) mkDriftCheck;
    semble = self.ciPackages.${system}.semble;
    # Validate the reader when checking drift, while leaving extraction buildable.
    committed = assert lib.assertMsg (languages.parsedLanguages != []) "packages/semble/lib/extracted.nix derives no parsed languages";
      ../extracted.json;
    languages = import ../lib/extracted.nix;

    extracted = semble.passthru.extracted;
  in
    mkDriftCheck {
      inherit committed extracted;
      name = "semble-languages";
      sidecar = "packages/semble/extracted.json";
    };
}
