{
  lib,
  harness,
  ...
}: let
  extracted = builtins.fromJSON (builtins.readFile ../extracted.json);
  rows = builtins.fromJSON (builtins.readFile ../extract/rollout-features.json);
  coverage = (import ../extract/rollout-coverage.nix).check;
  actual = coverage {inherit extracted lib rows;};
  control = kind: data: expected:
    harness.mkTest "kiro-rollout-coverage-${kind}-control" (
      actual.failures
      == []
      && (coverage (data // {inherit lib;})).failures == [expected]
    );
  feature = "background_execution";
  before = builtins.toJSON rows.${feature}.state;
  changed = rows.${feature}.state // {treatment_percent = 37;};
in {
  checks = {
    kiro-rollout-coverage-missing-row-control = control "missing-row" {
      inherit extracted;
      rows = builtins.removeAttrs rows [feature];
    } "rollout ${feature}: old \"MISSING REVIEW\" -> new ${before}";
    kiro-rollout-coverage-removed-feature-control = control "removed-feature" {
      inherit rows;
      extracted =
        extracted
        // {
          rolloutFeatures = lib.remove feature extracted.rolloutFeatures;
          rolloutStates = builtins.removeAttrs extracted.rolloutStates [feature];
        };
    } "rollout ${feature}: old ${before} -> new \"MISSING FEATURE\"";
    kiro-rollout-coverage-state-change-control = control "state-change" {
      inherit rows;
      extracted = extracted // {rolloutStates = extracted.rolloutStates // {${feature} = changed;};};
    } "rollout ${feature}: old ${before} -> new ${builtins.toJSON changed}";
  };
}
