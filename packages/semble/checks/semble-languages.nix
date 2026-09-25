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
    semble = self.packages.${system}.semble;
    committed = ../extracted.json;
    languages = import ../lib/extracted.nix;

    sembleScript = import ./semble-script.nix pkgs;
    extracted = pkgs.runCommand "semble-extracted.json" {} ''
      ${sembleScript "extract-languages" semble ./extract-languages.py} > "$out"
    '';
  in {
    semble-languages-extracted =
      pkgs.runCommand "semble-languages-extracted-drift" {
        passthru = {inherit extracted;};
        # Forces the eval-side reader over the committed file, so a reshaped
        # extractor cannot land with a reader that no longer evaluates. An
        # attribute rather than an assert, so `passthru.extracted` stays
        # buildable while extracted.json is being regenerated.
        parsedLanguageCount = assert lib.assertMsg (languages.parsedLanguages != []) "packages/semble/lib/extracted.nix derives no parsed languages";
          builtins.length languages.parsedLanguages;
      } ''
        if ${pkgs.jq}/bin/jq -e -n --slurpfile actual ${extracted} \
          --slurpfile committed ${committed} '$actual == $committed' > /dev/null; then
          echo "ok — packages/semble/extracted.json matches the pinned package" > "$out"
        else
          echo "FAIL: packages/semble/extracted.json is out of sync with the pinned Semble package." >&2
          echo "Regenerate: nix build .#checks.${system}.semble-languages-extracted.passthru.extracted --no-link --print-out-paths" >&2
          echo "Then copy the result over packages/semble/extracted.json and format it." >&2
          exit 1
        fi
      '';
  };
}
