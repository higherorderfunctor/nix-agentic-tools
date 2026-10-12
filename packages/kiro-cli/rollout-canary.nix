{
  kiro-cli,
  lib,
}: let
  extracted = import ../../lib/extracted/facts.nix {inherit lib;};
  inherit (extracted.load {dir = ./extracted;}) aggregate;
  inherit (import ./extract/rollout-coverage.nix) needsPatch;
  patchable = builtins.filter (name:
    needsPatch (extracted.get aggregate "rolloutStates.${name}")
    && extracted.get aggregate "rolloutPatchability.${name}.patchable")
  (extracted.get aggregate "rolloutFeatures");
in
  kiro-cli.withRolloutFeatures patchable
