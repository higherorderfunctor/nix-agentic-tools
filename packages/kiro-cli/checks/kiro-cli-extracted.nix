# Drift check — the committed packages/kiro-cli/extracted.json must match what
# the packaged kiro binary and the committed public model-table snapshot contain.
# Blocking (a typed trigger vanishing, or a documented-absent one becoming
# present, is a correctness signal the typed surface must react to). Mirrors
# packages/claude-code/checks/claude-code-extracted.nix; the build of passthru.extracted also enforces
# the fail-loud (>=1 present) guard baked into vu.mkKiroExtract.
{
  pkgs,
  self,
  ...
}: {
  checks = let
    inherit (pkgs.stdenv.hostPlatform) system;
    extracted = self.packages.${system}.kiro-cli.passthru.extracted;
    committed = ../extracted.json;
  in {
    kiro-cli-extracted = pkgs.runCommand "kiro-cli-extracted-drift" {} ''
      jq="${pkgs.jq}/bin/jq"
      if "$jq" -e -n --slurpfile a ${extracted} --slurpfile b ${committed} \
        '$a == $b' > /dev/null; then
        echo "ok — packages/kiro-cli/extracted.json matches the binary and public model snapshot" > $out
      else
        echo "FAIL: packages/kiro-cli/extracted.json is out of sync with its extraction sources." >&2
        echo "--- committed ---" >&2
        "$jq" -S . ${committed} >&2
        echo "--- extracted ---" >&2
        "$jq" -S . ${extracted} >&2
        echo "" >&2
        echo "Regenerate: nix build .#kiro-cli.passthru.extracted --no-link --print-out-paths" >&2
        echo "then cp the result over packages/kiro-cli/extracted.json, 'nix fmt' it, and 'git add'." >&2
        exit 1
      fi
    '';
    kiro-models-fixtures = pkgs.runCommand "kiro-models-fixtures" {} ''
      ${pkgs.python3}/bin/python3 ${./kiro-models.py} \
        ${../extract/models.py} ${../model-catalog.json}
      touch "$out"
    '';
  };
}
