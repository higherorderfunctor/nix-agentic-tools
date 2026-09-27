# Reverse coverage gate for the generated Codex vocabulary sidecar. The normal
# extracted check proves only that JSON matches the binary; this separate check
# proves that every extracted shape has a reviewed Nix disposition. Keep the
# classifications human-authored so the update self-heal cannot bless a new
# command or flag merely by regenerating both sides of a comparison.
{
  lib,
  pkgs,
  ...
}: {
  checks = let
    coverage = import ../lib/extractedCoverage.nix;
    extracted = builtins.fromJSON (builtins.readFile ../extracted.json);

    sorted = builtins.sort builtins.lessThan;
    flattenCategories = categories: lib.concatLists (builtins.attrValues categories);
    duplicateValues = values:
      lib.filter (value: builtins.length (lib.filter (candidate: candidate == value) values) > 1) (lib.unique values);

    # Every producer below returns a LIST of problem strings — empty when clean.
    # They are concatenated and reported in ONE throw at the bottom.
    #
    # This replaced a chain of 14 `assert`s. Nix short-circuits at the first
    # failing assert, so a bump that added six flags AND removed one command
    # reported only the command (PR #1578), and the fix took a CI round trip per
    # category. The categories are independent; there is no reason to run them one at a time
    # discovering them.
    #
    # ORIENTATION, and the trap this file fell into: `lib.subtractLists` takes
    # removals FIRST. So `missing` (new upstream, needs a disposition) is
    # extracted - covered, and `stale` (gone upstream, safe to delete) is
    # covered - extracted. Six call sites used to pass these the wrong way
    # round, which printed an ADDITION as "stale dispositions" — the exact
    # opposite of what happened, to whoever reads it. Two guards now:
    # the argument names below, and `recordFieldProblems` doing the swap ONCE
    # rather than at each of its four call sites.
    exactProblems = label: extractedValues: coveredValues: let
      missing = lib.subtractLists coveredValues extractedValues;
      stale = lib.subtractLists extractedValues coveredValues;
    in
      lib.optional (sorted extractedValues != sorted coveredValues)
      "${label}: missing dispositions (new upstream, classify these): ${builtins.toJSON missing}; stale dispositions (gone upstream, safe to delete): ${builtins.toJSON stale}";

    # `noun` is not decoration. Two of the three call sites check the COVERAGE
    # lists, where a duplicate is a classification mistake; the third checks a
    # command's flag names straight out of the EXTRACTION, where a duplicate
    # means the extractor emitted the same flag twice. Calling both "duplicate
    # dispositions" sent the reader to the wrong file.
    duplicateProblems = noun: label: values:
      lib.optional (builtins.length values != builtins.length (lib.unique values))
      "${label}: duplicate ${noun}: ${builtins.toJSON (duplicateValues values)}";

    # `expected` is the COVERAGE side, so it goes in the covered slot. Doing the
    # orientation here keeps all four record-field call sites reading naturally.
    recordFieldProblems = label: expected: records:
      lib.unique (lib.concatMap (record: exactProblems label (builtins.attrNames record) expected) records);

    # Maturities are a POLICY list, not a ledger of what upstream ships. An
    # exact match went red whenever upstream stopped shipping any feature at
    # some maturity — demanding the deletion of a policy that is still correct.
    # Only the other direction is a real gap: a maturity we have no policy for.
    subsetProblems = label: observed: allowed:
      lib.optional (lib.subtractLists allowed observed != [])
      "${label}: no policy for ${builtins.toJSON (lib.subtractLists allowed observed)}";

    commands = builtins.attrValues extracted.cli.commands;
    commandNames = builtins.attrNames extracted.cli.commands;
    coveredCommands = flattenCategories coverage.cli.commands;
    canonicalFlags = lib.unique (lib.concatMap (command: map (flag: builtins.head flag.names) command.flags) commands);
    coveredFlags = flattenCategories coverage.cli.flags;
    rootCanonicalFlags = map (flag: builtins.head flag.names) extracted.cli.commands.codex.flags;
    globalCanonicalFlags = map (flag: builtins.head flag.names) extracted.cli.globalFlags;
    featureMaturities = lib.unique (map (feature: feature.maturity) extracted.features);
    rootFlagNames = lib.concatMap (flag: flag.names) extracted.cli.commands.codex.flags;
    # A flag a launcher always passes is policy mkCodex.nix depends on. If
    # upstream drops it, the exact check above also calls its disposition
    # "stale, safe to delete"; this problem says why it is not.
    launcherFlagProblems = lib.concatLists (lib.mapAttrsToList (backend: flags:
      lib.optional (lib.subtractLists rootFlagNames flags != [])
      "${backend} launcher flags ${builtins.toJSON (lib.subtractLists rootFlagNames flags)} are gone from upstream's root flags: they are mkCodex.nix launcher policy (extractedCoverage.nix cli.launcherFlags), so do not just delete the disposition; redesign the ${backend} launcher first")
    coverage.cli.launcherFlags);
    problems = lib.concatLists [
      (exactProblems "CLI commands" commandNames coveredCommands)
      (duplicateProblems "dispositions" "CLI commands" coveredCommands)
      (recordFieldProblems "CLI command fields" (builtins.attrNames coverage.cli.commandFields) commands)
      (lib.concatMap (command:
        duplicateProblems "extracted flag names" "CLI flags for ${builtins.concatStringsSep " " command.path}"
        (map (flag: builtins.head flag.names) command.flags))
      commands)
      (exactProblems "CLI flags" canonicalFlags coveredFlags)
      (duplicateProblems "dispositions" "CLI flags" coveredFlags)
      (recordFieldProblems "CLI flag fields" (builtins.attrNames coverage.cli.flagFields) (lib.concatMap (command: command.flags) commands))
      # Extractor-internal invariant, not a human ledger: both sides come from
      # the extraction, so "missing/stale" vocabulary would not apply. Kept
      # exact in both directions.
      (lib.optional (sorted rootCanonicalFlags != sorted globalCanonicalFlags)
        "global flags versus root command flags disagree; extraction is internally inconsistent: root ${builtins.toJSON (sorted rootCanonicalFlags)} vs global ${builtins.toJSON (sorted globalCanonicalFlags)}")
      (exactProblems "config vocabulary fields" (builtins.attrNames extracted.config) (builtins.attrNames coverage.config))
      (lib.optional (!lib.all (values: values == []) (builtins.attrValues extracted.config))
        "config extraction is no longer empty; classify each extracted key before accepting the new seam")
      (recordFieldProblems "feature fields" (builtins.attrNames coverage.features.fields) extracted.features)
      (subsetProblems "feature maturities" featureMaturities (builtins.attrNames coverage.features.maturities))
      (recordFieldProblems "model fields" (builtins.attrNames coverage.models) extracted.models)
      (exactProblems "provenance fields" (builtins.attrNames extracted.provenance) (builtins.attrNames coverage.provenance))
      launcherFlagProblems
    ];
  in
    assert lib.assertMsg (problems == [])
    ("chatgpt-codex coverage drift (${toString (builtins.length problems)} ${
        if builtins.length problems == 1
        then "problem"
        else "problems"
      }):\n  - "
      + builtins.concatStringsSep "\n  - " problems); {
      chatgpt-codex-coverage = pkgs.runCommand "chatgpt-codex-coverage" {} ''
        echo "ok — every extracted Codex vocabulary has a reviewed Nix disposition" > "$out"
      '';
    };
}
