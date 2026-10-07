# Drift gate for packages/semble/extracted.json, Semble's language knowledge:
# the grammars semble-grammars bundles, the extension map, and the
# language sets behind each content type.
#
# Extraction reads the pinned package output in a separate derivation; the
# Semble derivation itself stays byte-for-byte identical to llm-agents.nix.
# The update pipeline regenerates the file on every llm-agents bump
# (dev/scripts/update-input.sh), so a bot PR carries it instead of failing
# this check.
{
  lib,
  pkgs,
  self,
  ...
}: {
  checks = let
    inherit (pkgs.stdenv.hostPlatform) system;
    inherit (import ../../../lib/extracted {inherit pkgs;}) mkDriftCheck;
    semble = self.ciPackages.${system}.semble;
    # Validate the reader when checking drift, while leaving extraction buildable.
    committed = assert lib.assertMsg (languages.parsedLanguages != []) "packages/semble/lib/extracted.nix derives no parsed languages";
      ../extracted.json;
    languages = import ../lib/extracted.nix;

    sembleScript = import ./semble-script.nix pkgs;
    extracted = pkgs.runCommand "semble-extracted.json" {} ''
      ${sembleScript "extract-languages" semble ./extract-languages.py} > "$out"
    '';
  in
    mkDriftCheck {
      inherit committed extracted;
      name = "semble-languages";
      sidecar = "packages/semble/extracted.json";
    };
}
