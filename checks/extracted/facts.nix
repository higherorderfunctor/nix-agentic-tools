# Fixtures for lib/extracted/facts.nix. Every case cites the clause of
# dev/fragments/extracted/facts-contract.md (as of 754dd6bb) it tests as
# `spec:<line>`; where
# this suite and the implementation disagree, the contract decides.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (import ../../lib/extracted/facts.nix {inherit lib;}) expect get getFor merge;
  systems = import ../../config/systems.nix;
  both = tree: lib.genAttrs systems (_: tree);
  split = darwin: linux: {
    aarch64-darwin = darwin;
    x86_64-linux = linux;
  };
  static = type: {
    inherit type;
    source = "static";
  };
  decision = combine: {
    inherit combine;
    decided = "2026-10-10";
    reason = "fixture";
  };
  divergent = {
    declarations.mode = static "string";
    raws = split {mode = "darwin-value";} {mode = "linux-value";};
  };
  # Every case names its refused input or the consumer-visible result.
  # `kinds` is merge's failure kinds, compared exactly; `shows` is the visible
  # result.
  cases = {
    # Fixture 1; spec:216, spec:122.
    agree = {
      input = {
        declarations.mode = static "string";
        raws = both {mode = "same";};
      };
      kinds = [];
      shows = result: get result.aggregate "mode" == "same";
    };
    # Fixture 11; spec:81, spec:149.
    bad-decision-blank-reason = {
      input = {
        declarations.mode = static "string";
        decisions.mode = decision "equal" // {reason = " ";};
        raws = both {mode = "same";};
      };
      kinds = ["bad-decision"];
    };
    # Fixture 11; spec:81, spec:138-139, spec:149.
    bad-decision-impossible-date = {
      input = {
        declarations.mode = static "string";
        decisions.mode = decision "equal" // {decided = "2026-02-31";};
        raws = both {mode = "same";};
      };
      kinds = ["bad-decision"];
    };
    # Fixture 11; spec:149.
    bad-decision-undeclared-key = {
      input = {
        declarations.mode = static "string";
        decisions.ghost = decision "equal";
        raws = both {mode = "same";};
      };
      kinds = ["bad-decision"];
    };
    # Fixture 11; spec:84-85, spec:149.
    bad-decision-unknown-combine = {
      input = {
        declarations.mode = static "string";
        decisions.mode = decision "average";
        raws = both {mode = "same";};
      };
      kinds = ["bad-decision"];
    };
    # Fixture 6; spec:147. Same shape as live-no-systems minus the live
    # declaration, so that case cannot pass by reporting nothing.
    declared-gone = {
      input = {
        declarations.lastRun = static "string";
        raws = both {};
      };
      kinds = ["declared-gone"];
    };
    # Fixture 2; spec:93.
    differ-bool-and = {
      input = {
        declarations.enabled = static "bool";
        raws = split {enabled = true;} {enabled = false;};
      };
      kinds = [];
      shows = result:
        get result.aggregate "enabled"
        == false
        && result.aggregate.enabled.combine == "and";
    };
    # Fixture 2; spec:84, spec:96 (overridden by a decision).
    differ-count-max = {
      input = {
        declarations.limit = static "count";
        decisions.limit = decision "max";
        raws = split {limit = 3;} {limit = 5;};
      };
      kinds = [];
      shows = result:
        get result.aggregate "limit"
        == 5
        && result.aggregate.limit.combine == "max";
    };
    # Fixture 2; spec:56, spec:95.
    differ-set-intersection = {
      input = {
        declarations.models = static "set";
        raws = split {models = ["a" "b"];} {models = ["c" "b"];};
      };
      kinds = [];
      shows = result:
        get result.aggregate "models"
        == ["b"]
        && result.aggregate.models.combine == "intersection";
    };
    # Fixture 2; spec:85.
    differ-string-prefer = {
      input = {
        declarations.mode = static "string";
        decisions.mode = decision "prefer:x86_64-linux";
        raws = split {mode = "darwin-value";} {mode = "linux-value";};
      };
      kinds = [];
      shows = result:
        get result.aggregate "mode"
        == "linux-value"
        && result.aggregate.mode.combine == "prefer:x86_64-linux";
    };
    # Fixture 3; spec:101-102, spec:132-135, spec:145. The fix row itself is
    # checked by checks.extracted-facts-divergent-fix.
    divergent = {
      input = divergent;
      kinds = ["divergent"];
      shows = result: let
        details = builtins.toJSON (lib.head result.failures).details;
      in
        lib.all (value: lib.hasInfix value details) ["darwin-value" "linux-value"];
    };
    # Fixture 3; spec:135-139. Pasted unedited, the row is refused naming both
    # placeholders; with both filled in, merge is clean.
    divergent-fix-pasted = {
      input = divergent;
      kinds = ["divergent"];
      shows = _: let
        pasted = merge (divergent
          // {
            inherit systems;
            decisions = fixRows;
          });
        refused = lib.filter (failure: failure.kind == "bad-decision") pasted.failures;
        named = builtins.toJSON (map (failure: {inherit (failure) details fix;}) refused);
        edited = merge (divergent
          // {
            inherit systems;
            decisions = lib.mapAttrs (_: row:
              row
              // {
                decided = "2026-10-10";
                reason = "fixture";
              })
            fixRows;
          });
      in
        refused
        != []
        && lib.all (field: lib.hasInfix field named) ["decided" "reason"]
        && edited.failures == [];
    };
    # Fixture 9; spec:171-187.
    expect = {
      input = {
        declarations = {
          hookTriggers = static "set";
          "steering.maxChars" = static "count";
          tools = static "set";
        };
        raws = both {
          hookTriggers = ["stop"];
          steering.maxChars = 50000;
          tools = ["invoke_sub_agent" "read"];
        };
      };
      kinds = [];
      shows = result: let
        consumer = "delegate-routing";
        satisfied = expect {
          inherit (result) aggregate;
          inherit consumer;
          needs = [
            {
              contains = "invoke_sub_agent";
              key = "tools";
            }
            {
              key = "steering.maxChars";
              value = 50000;
            }
            {key = "hookTriggers";}
          ];
        };
        failed = expect {
          inherit (result) aggregate;
          inherit consumer;
          needs = [
            {
              contains = "write";
              key = "tools";
            }
            {
              key = "steering.maxChars";
              value = 1;
            }
          ];
        };
        # `expected` is the need's payload, bare or with its own field name.
        shown = key: expected: actual: let
          failure = lib.findFirst (failure: failure.key == key) {} failed.failures;
        in
          failure.kind or null
          == "expectation"
          && failure.consumer or null == consumer
          && builtins.elem (failure.expected or null) [expected.${lib.head (builtins.attrNames expected)} expected]
          && failure.actual or null == actual;
      in
        satisfied.failures
        == []
        && builtins.length failed.failures == 2
        && shown "tools" {contains = "write";} (get result.aggregate "tools")
        && shown "steering.maxChars" {value = 1;} 50000;
    };
    # Fixture 12; spec:82.
    ignore-before-intersection = {
      input = {
        declarations.models = static "set";
        decisions.models = decision "intersection" // {ignore = ["preview"];};
        raws = both {models = ["a" "preview"];};
      };
      kinds = [];
      shows = result: get result.aggregate "models" == ["a"];
    };
    # Fixture 14; spec:53-54, spec:147, spec:152-153.
    live-no-systems = {
      input = {
        declarations.lastRun = {
          source = "live";
          systems = [];
          type = "string";
        };
        raws = both {};
      };
      kinds = [];
    };
    # Fixture 13; spec:54, spec:146.
    missing-system = {
      input = {
        declarations.limit = static "count";
        raws = split {} {limit = 5;};
      };
      kinds = ["missing-system"];
    };
    # Fixture 8; spec:87-88, spec:122, spec:164-166.
    per-platform = {
      input = {
        declarations.limit = static "count";
        decisions.limit = decision "per-platform";
        raws = split {limit = 3;} {limit = 5;};
      };
      kinds = [];
      shows = result:
        !(result.aggregate.limit ? value)
        && !(builtins.tryEval (get result.aggregate "limit")).success
        && getFor "aarch64-darwin" result.aggregate "limit" == 3
        && getFor "x86_64-linux" result.aggregate "limit" == 5;
    };
    # Fixture 7; spec:56, spec:148. Required on one system only, so exactly one
    # raw value is checked.
    type-mismatch = {
      input = {
        declarations.limit = static "count" // {systems = ["x86_64-linux"];};
        raws = split {} {limit = "five";};
      };
      kinds = ["type-mismatch"];
    };
    # Fixture 4; spec:127, spec:152.
    undeclared = {
      input = {
        declarations.mode = static "string";
        raws = both {
          mode = "same";
          newThing = "value";
        };
      };
      kinds = [];
      shows = result: result.undeclared == ["newThing"];
    };
    # Fixture 5; spec:117, spec:150.
    undeclared-secret = {
      input = {
        declarations.mode = static "string";
        raws = both {
          apiToken = "value";
          mode = "same";
        };
      };
      kinds = ["undeclared-secret"];
    };
    # Fixture 10; spec:30-33, spec:155-156. `new` has no row of its own and is still
    # declared and combined.
    wildcard = {
      input = {
        declarations."features.<name>.state" = static "string";
        raws = both {
          features = {
            new.state = "off";
            old.state = "on";
          };
        };
      };
      kinds = [];
      shows = result:
        result.undeclared
        == []
        && get result.aggregate "features.new.state" == "off"
        && get result.aggregate "features.old.state" == "on";
    };
  };
  run = case: let
    result = merge (case.input // {inherit systems;});
  in
    map (failure: failure.kind) result.failures
    == case.kinds
    && (case.shows or (_: true)) result;
  failures = builtins.attrNames (lib.filterAttrs (_: case: !(run case)) cases);
  # spec:132-139: the divergent fix is a complete decisions.json row, pasted
  # into the decisions object bare or wrapped.
  fixText = (lib.head (merge (divergent // {inherit systems;})).failures).fix;
  fixRows = builtins.fromJSON (
    if lib.hasPrefix "{" (lib.trim fixText)
    then fixText
    else "{${fixText}}"
  );
  vocabulary = ["and" "equal" "ignore" "intersection" "max" "min" "or" "per-platform" "union"] ++ map (system: "prefer:${system}") systems;
in {
  checks = {
    extracted-facts = harness.mkTest "extracted-facts" (
      assert lib.assertMsg (failures == []) (builtins.toJSON failures); true
    );
    extracted-facts-divergent-fix = pkgs.runCommand "extracted-facts-divergent-fix" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      jq="${pkgs.jq}/bin/jq"
      "$jq" -e --argjson vocabulary '${builtins.toJSON vocabulary}' '
        keys == ["mode"]
        and (.mode.combine | IN($vocabulary[]))
        and (.mode.reason | type == "string" and startswith("TODO"))
        and .mode.decided == "YYYY-MM-DD"
      ' ${pkgs.writeText "divergent-fix.json" (builtins.toJSON fixRows)} > /dev/null || {
        echo "FAIL: divergent fix is not a complete decisions.json row:" >&2
        cat ${pkgs.writeText "divergent-fix" fixText} >&2
        exit 1
      }
      echo "PASS: extracted-facts-divergent-fix" > "$out"
    '';
  };
}
