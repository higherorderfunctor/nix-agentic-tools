{
  extractedLib,
  pkgs,
  ...
}: let
  extracted = extractedLib {inherit pkgs;};
  facts = extracted.load {dir = ../extracted;};
  # Read through the same fact loader as Kiro's suggestions, not the raw JSON.
  committed = pkgs.writeText "kiro-models.json" (builtins.toJSON {models = extracted.get facts.aggregate "models";});
in {
  checks.kiro-models-fixtures = pkgs.runCommand "kiro-models-fixtures" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${pkgs.python3}/bin/python3 ${./catalog.py} ${../extract/catalog.py} ${committed}
    touch "$out"
  '';
}
