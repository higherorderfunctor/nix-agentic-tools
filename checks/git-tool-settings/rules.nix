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
  # `null` leaves the name out of facts or rows.
  run = {
    deadFact ? null,
    deadRow ? null,
    expectedDead ? {},
    expectedFailures ? [],
    expectedSettings,
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
    && results.deadKeys.failures ++ results.settings.failures == expectedFailures;
  cases = {
    computed-default-described = run {
      expectedSettings."probe.key" = computed // {defaultDescription = "what probe() returns";};
      settingFact = computed;
      settingRow.defaultDescription = "what probe() returns";
    };
    computed-default-without-prose = run {
      expectedSettings."probe.key" = computed;
      settingFact = computed;
    };
    # A dead key read again is a setting, and its reason row goes stale.
    dead-key-read-again = run {
      deadRow = reason;
      expectedFailures = [
        {
          details = "delete the stale row";
          kind = "removed";
          name = "probe.key";
          surface = "deadKeys";
        }
      ];
      expectedSettings."probe.key" = setting;
      settingFact = setting;
      settingRow = {};
    };
    dead-key-reasoned = run {
      deadFact = dead;
      deadRow = reason;
      expectedDead."probe.key" = dead // reason;
      expectedSettings = {};
    };
    dead-key-without-reason = run {
      deadFact = dead;
      expectedDead."probe.key" = dead;
      expectedSettings = {};
    };
    new-setting-accepted = run {
      expectedSettings."probe.key" = setting;
      settingFact = setting;
    };
    read-setting-needs-type = let
      untyped = builtins.removeAttrs setting ["type"];
    in
      run {
        expectedFailures = [
          {
            details = ["type"];
            kind = "needs-human";
            name = "probe.key";
            surface = "settings";
          }
        ];
        expectedSettings."probe.key" = untyped;
        settingFact = untyped;
      };
    read-setting-without-description = let
      undescribed = builtins.removeAttrs setting ["description"];
    in
      run {
        expectedSettings."probe.key" = undescribed;
        settingFact = undescribed;
      };
    # An ignored row would drop the option and skip its needs, unreported.
    settings-row-cannot-ignore = run {
      expectedFailures = [
        {
          details = ["a settings row cannot be ignored; give the key no option in the owner's `exclusions`"];
          kind = "bad-row";
          name = "probe.key";
          surface = "settings";
        }
      ];
      expectedSettings = {};
      settingFact = setting;
      settingRow.ignored = "probe";
    };
    # A write-only key becomes no option, so it needs no type.
    write-only-setting-accepted = let
      written = {
        reads = {};
        writes."probe.rs#write" = ["repository"];
      };
    in
      run {
        expectedSettings."probe.key" = written;
        settingFact = written;
      };
  };
in {
  checks.git-tool-settings-rules = mkTest "git-tool-settings-rules" (checkRows "git-tool-settings reconciliation" cases);
}
