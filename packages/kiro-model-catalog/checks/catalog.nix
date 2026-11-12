{
  extractedLib,
  pkgs,
  ...
}: let
  extracted = extractedLib {inherit pkgs;};
  facts = extracted.load {dir = ../extracted;};
  consumers = extracted.expect {
    inherit (facts) aggregate;
    consumer = "kiro-model-catalog";
    needs = [{key = "models";}];
  };
  committed = pkgs.writeText "kiro-models.json" (builtins.toJSON {models = extracted.get facts.aggregate "models";});
in {
  checks.kiro-models-fixtures = assert facts.failures == [] && consumers.failures == [];
    pkgs.runCommand "kiro-models-fixtures" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${pkgs.python3}/bin/python3 ${./catalog.py} ${../extract/catalog.py} ${committed}
      touch "$out"
    '';
}
