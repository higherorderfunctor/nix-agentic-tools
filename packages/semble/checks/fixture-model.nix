# A tiny model2vec model, built offline from Semble's own closure. Distinct
# seeds give distinct models.
pkgs: seed:
pkgs.runCommand "semble-fixture-model-${toString seed}" {} ''
  ${import ./semble-script.nix pkgs "fixture-model" pkgs.ai.semble ./fixture-model.py} "$out" ${toString seed}
''
