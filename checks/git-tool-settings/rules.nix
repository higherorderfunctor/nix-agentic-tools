# lib/git-tool-settings/rules.nix: what the git tools' surface table adds to
# the new-key rule, which checks/extracted/reconcile.nix covers in general.
# Each case is one sidecar fact and its row, and the failures it must give.
{
  harness,
  lib,
  ...
}: let
  setting = {
    description = "Probe.";
    reads."probe.rs#read" = ["repository"];
    type = "bool";
  };
  cases = {
    computed-default-described = {
      settings.fact = setting // {defaultExpr = "probe()";};
      settings.row = {defaultDescription = "what probe() returns";};
      kinds = [];
    };
    computed-default-without-prose = {
      settings.fact = setting // {defaultExpr = "probe()";};
      settings.row = null;
      kinds = [];
    };
    # A dead key read again is a setting, and its reason row goes stale.
    dead-key-read-again = {
      deadKeys.fact = null;
      deadKeys.row = {reason = "declared, never read";};
      settings.fact = setting;
      settings.row = {};
      kinds = ["removed"];
    };
    dead-key-reasoned = {
      deadKeys.fact = {const = "PROBE";};
      deadKeys.row = {reason = "declared, never read";};
      kinds = [];
    };
    dead-key-without-reason = {
      deadKeys.fact = {const = "PROBE";};
      deadKeys.row = null;
      kinds = [];
    };
    new-setting-accepted = {
      settings.fact = setting;
      settings.row = null;
      kinds = [];
    };
    read-setting-needs-type = {
      settings.fact = builtins.removeAttrs setting ["type"];
      settings.row = null;
      kinds = ["needs-human"];
    };
    read-setting-without-description = {
      settings.fact = builtins.removeAttrs setting ["description"];
      settings.row = null;
      kinds = [];
    };
    # An ignored row would drop the option and skip its needs, unreported.
    settings-row-cannot-ignore = {
      settings.fact = setting;
      settings.row = {ignored = "probe";};
      kinds = ["bad-row"];
    };
    # A write-only key becomes no option, so nothing needs its prose.
    write-only-setting-accepted = {
      settings.fact = {
        reads = {};
        type = "string";
        writes."probe.rs#write" = ["repository"];
      };
      settings.row = null;
      kinds = [];
    };
  };
  # `null` leaves the name out of facts or rows.
  section = surface: case: field:
    lib.optionalAttrs ((case.${surface}.${field} or null) != null) {"probe.key" = case.${surface}.${field};};
  run = case: let
    of = field: lib.genAttrs ["deadKeys" "settings"] (surface: section surface case field);
    inherit
      (import ../../lib/git-tool-settings/rules.nix {
        inherit lib;
        extracted = of "fact";
        rows = of "row";
      })
      results
      ;
  in
    map (failure: failure.kind) (results.deadKeys.failures ++ results.settings.failures)
    == case.kinds;
  failed = builtins.attrNames (lib.filterAttrs (_: case: !(run case)) cases);
in {
  checks.git-tool-settings-rules = harness.mkTest "git-tool-settings-rules" (
    lib.assertMsg (failed == []) "git-tool-settings-rules: FAILED ${lib.concatStringsSep ", " failed}"
  );
}
