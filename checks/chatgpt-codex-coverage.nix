# Reverse coverage gate for the generated Codex vocabulary sidecar. The normal
# extracted check proves only that JSON matches the binary; this separate check
# proves that every extracted shape has a reviewed Nix disposition. Keep the
# classifications human-authored so the update self-heal cannot bless a new
# command or flag merely by regenerating both sides of a comparison.
{
  lib,
  pkgs,
}: let
  coverage = import ../packages/chatgpt-codex/lib/extractedCoverage.nix;
  extracted = builtins.fromJSON (builtins.readFile ../overlays/chatgpt-codex-extracted.json);

  sorted = builtins.sort builtins.lessThan;
  flattenCategories = categories: lib.concatLists (builtins.attrValues categories);
  duplicateValues = values:
    lib.filter (value: builtins.length (lib.filter (candidate: candidate == value) values) > 1) (lib.unique values);
  exactMessage = label: extractedValues: coveredValues: let
    # lib.subtractLists takes removals first and candidates second. Missing
    # dispositions are therefore extracted - covered; stale dispositions are
    # covered - extracted. Naming both sets prevents the tempting reversal.
    missing = lib.subtractLists coveredValues extractedValues;
    unexpected = lib.subtractLists extractedValues coveredValues;
  in "chatgpt-codex coverage drift in ${label}; missing dispositions: ${builtins.toJSON missing}; stale dispositions: ${builtins.toJSON unexpected}";
  assertExact = label: extractedValues: coveredValues:
    lib.assertMsg (sorted extractedValues == sorted coveredValues) (exactMessage label extractedValues coveredValues);
  assertUnique = label: values:
    lib.assertMsg (builtins.length values == builtins.length (lib.unique values))
    "chatgpt-codex coverage duplicates in ${label}: ${builtins.toJSON (duplicateValues values)}";
  assertRecordFields = label: expected: records:
    lib.all (record: assertExact label expected (builtins.attrNames record)) records;

  commands = builtins.attrValues extracted.cli.commands;
  commandNames = builtins.attrNames extracted.cli.commands;
  coveredCommands = flattenCategories coverage.cli.commands;
  canonicalFlags = lib.unique (lib.concatMap (command: map (flag: builtins.head flag.names) command.flags) commands);
  coveredFlags = flattenCategories coverage.cli.flags;
  rootCanonicalFlags = map (flag: builtins.head flag.names) extracted.cli.commands.codex.flags;
  globalCanonicalFlags = map (flag: builtins.head flag.names) extracted.cli.globalFlags;
  featureMaturities = lib.unique (map (feature: feature.maturity) extracted.features);
in
  assert assertExact "CLI commands" commandNames coveredCommands;
  assert assertUnique "CLI commands" coveredCommands;
  assert assertRecordFields "CLI command fields" (builtins.attrNames coverage.cli.commandFields) commands;
  assert lib.all (command:
    assertUnique "CLI flags for ${builtins.concatStringsSep " " command.path}"
    (map (flag: builtins.head flag.names) command.flags))
  commands;
  assert assertExact "CLI flags" canonicalFlags coveredFlags;
  assert assertUnique "CLI flags" coveredFlags;
  assert assertRecordFields "CLI flag fields" (builtins.attrNames coverage.cli.flagFields) (lib.concatMap (command: command.flags) commands);
  assert assertExact "global flags versus root command flags" rootCanonicalFlags globalCanonicalFlags;
  assert assertExact "config vocabulary fields" (builtins.attrNames coverage.config) (builtins.attrNames extracted.config);
  assert lib.assertMsg (lib.all (values: values == []) (builtins.attrValues extracted.config))
  "chatgpt-codex config extraction is no longer empty; classify each extracted key before accepting the new seam";
  assert assertRecordFields "feature fields" (builtins.attrNames coverage.features.fields) extracted.features;
  assert assertExact "feature maturities" featureMaturities (builtins.attrNames coverage.features.maturities);
  assert assertRecordFields "model fields" (builtins.attrNames coverage.models) extracted.models;
  assert assertExact "provenance fields" (builtins.attrNames coverage.provenance) (builtins.attrNames extracted.provenance); {
    chatgpt-codex-coverage = pkgs.runCommand "chatgpt-codex-coverage" {} ''
      echo "ok — every extracted Codex vocabulary has a reviewed Nix disposition" > "$out"
    '';
  }
