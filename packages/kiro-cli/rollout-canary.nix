{kiro-cli}: let
  extracted = builtins.fromJSON (builtins.readFile ./extracted.json);
  rolloutCoverage = import ./extract/rollout-coverage.nix;
  patchable = builtins.filter (name:
    rolloutCoverage.needsPatch extracted.rolloutStates.${name}
    && extracted.rolloutPatchability.${name}.patchable)
  extracted.rolloutFeatures;
in
  kiro-cli.withRolloutFeatures patchable
