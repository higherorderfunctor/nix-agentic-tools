# cspell:ignore undescribed
# lib/git-tool-settings/rules.nix: the git tools' reconciliation rules.
# checks/extracted/reconcile.nix covers the shared rules.
# Each case names its facts and hand rows, and the entries and failures they produce.
{
  harness,
  lib,
  ...
}: let
  inherit (harness) checkRows mkTest;

  setting = {
    description = "Probe.";
    reads."probe.rs#read" = ["repository"];
    type = "bool";
  };
  computed = setting // {defaultExpr = "probe()";};
  dead = {const = "PROBE";};
  reason = {reason = "declared, never read";};
  failure = surface: kind: details: {
    inherit details kind surface;
    name = "probe.key";
  };
  # `null` leaves the name out of facts or rows.
  run = {
    deadFact ? null,
    deadRow ? null,
    expectedDead ? {},
    expectedDeadFailures ? [],
    expectedSettings ? {},
    expectedSettingsFailures ? [],
    settingFact ? null,
    settingRow ? null,
  }: let
    entry = value: lib.optionalAttrs (value != null) {"probe.key" = value;};
    inherit
      (import ../../lib/git-tool-settings/rules.nix {
        inherit lib;
        extracted = {
          deadKeys = entry deadFact;
          settings = entry settingFact;
        };
        rows = {
          deadKeys = entry deadRow;
          settings = entry settingRow;
        };
      })
      results
      ;
  in
    results.deadKeys.entries
    == expectedDead
    && results.settings.entries == expectedSettings
    && results.deadKeys.failures == expectedDeadFailures
    && results.settings.failures == expectedSettingsFailures;
  cases = {
    "a computed default keeps its expression alongside hand prose" = {
      expectedSettings."probe.key" = computed // {defaultDescription = "what probe() returns";};
      settingFact = computed;
      settingRow.defaultDescription = "what probe() returns";
    };
    "a computed default without hand prose still reconciles" = {
      expectedSettings."probe.key" = computed;
      settingFact = computed;
    };
    "a dead key keeps its hand reason without losing its constant" = {
      deadFact = dead;
      deadRow = reason;
      expectedDead."probe.key" = dead // reason;
    };
    "a dead key without a hand reason remains in the dead-key facts" = {
      deadFact = dead;
      expectedDead."probe.key" = dead;
    };
    "a dead key read again is a setting and its old reason is stale" = {
      deadRow = reason;
      expectedDeadFailures = [(failure "deadKeys" "removed" "delete the stale row")];
      expectedSettings."probe.key" = setting;
      settingFact = setting;
      settingRow = {};
    };
    "a read key without a type reports the missing type" = let
      untyped = builtins.removeAttrs setting ["type"];
    in {
      expectedSettings."probe.key" = untyped;
      expectedSettingsFailures = [(failure "settings" "needs-human" ["type"])];
      settingFact = untyped;
    };
    "a typed read key needs neither a hand row nor a description" = let
      undescribed = builtins.removeAttrs setting ["description"];
    in {
      expectedSettings."probe.key" = undescribed;
      settingFact = undescribed;
    };
    # An ignored row would drop the option and skip its needs, unreported.
    "an ignored settings row reports the forbidden bypass of exclusions" = {
      expectedSettingsFailures = [
        (failure "settings" "bad-row" ["a settings row cannot be ignored; give the key no option in the owner's `exclusions`"])
      ];
      settingFact = setting;
      settingRow.ignored = "probe";
    };
    # A write-only key becomes no option, so it needs no type.
    "an untyped write-only key reconciles without a missing-type failure" = let
      written = {
        reads = {};
        writes."probe.rs#write" = ["repository"];
      };
    in {
      expectedSettings."probe.key" = written;
      settingFact = written;
    };
  };
in {
  checks.git-tool-settings-rules = mkTest "git-tool-settings-rules" (
    checkRows "git-tool-settings reconciliation" (lib.mapAttrs (_: run) cases)
  );
}
