# Fixtures for lib/extracted/facts.nix. Each group is a table of inputs and
# the result the contract (dev/fragments/extracted/facts-contract.md) says
# they give; each group's comment names its section. Where this suite and
# the implementation disagree, the contract decides.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (import ../../lib/extracted/facts.nix {inherit lib;}) children expect get load merge;
  inherit (import ../../lib/extracted {inherit pkgs;}) index;
  systems = import ../../config/systems.nix;
  run = input: merge (input // {inherit systems;});
  kinds = result: map (failure: failure.kind) result.failures;
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
  # The divergent fix, parsed as the wrapped decisions.json object it is.
  fixText = (lib.head (run divergent).failures).fix;
  fixRows = builtins.fromJSON fixText;

  groups = {
    # `children`: exact wildcard leaves, disappearing children and get's
    # refusal of a child whose value must be read per system.
    children = let
      pattern = "features.<name>.state";
      input = {
        declarations = {
          "features.<name>.state" = static "string";
          "other.features.old.state" = static "string";
        };
        raws = both {
          features = {
            new.state = "on";
            old.state = "off";
          };
          other.features.old.state = "unrelated";
        };
      };
      matched = run input;
      empty = run {
        declarations.${pattern} = static "string";
        raws = both {features = {};};
      };
      platform = run (input // {decisions.${pattern} = decision "per-platform";});
      refuses = aggregate: key: !(builtins.tryEval (builtins.deepSeq (children aggregate key) true)).success;
    in {
      empty = children empty.aggregate pattern == {};
      matches-two =
        children matched.aggregate pattern
        == {
          new = "on";
          old = "off";
        };
      multiple-wildcards-throws = refuses matched.aggregate "<name>.<name>.state";
      no-wildcard-throws = refuses matched.aggregate "features.old.state";
      per-platform-throws = refuses platform.aggregate pattern;
    };

    # Decisions: consumer combinations and their defaults. A key `k`
    # differs (or not) across systems; columns: combine, type, Darwin raw,
    # Linux raw, combined value. `set` is compared without order.
    combines = let
      combined = written: combine: type: darwin: linux: value: let
        result = run ({
            declarations.k = static type;
            raws = split {k = darwin;} {k = linux;};
          }
          // lib.optionalAttrs written {decisions.k = decision combine;});
        normal =
          if type == "set"
          then lib.sort builtins.lessThan
          else lib.id;
      in
        kinds result == [] && result.aggregate.k.combine == combine && normal (get result.aggregate "k") == normal value;
      byDefault = combined false;
      decided = combined true;
    in {
      bool-and = byDefault "and" "bool" true false false;
      list-agree = byDefault "equal" "list" ["b" "a"] ["b" "a"] ["b" "a"];
      object-agree = byDefault "equal" "object" {a.b = 1;} {a.b = 1;} {a.b = 1;};
      set-intersection = byDefault "intersection" "set" ["a" "b"] ["c" "b"] ["b"];
      set-union = decided "union" "set" ["a" "b"] ["c" "b"] ["c" "b" "a"];
    };

    # `merge`, failure kinds: `divergent` under an effective `equal`, with
    # every system's value in `details`. Columns: type, Darwin raw, Linux raw.
    divergence = let
      diverges = type: darwin: linux: let
        result = run {
          declarations.k = static type;
          raws = split {k = darwin;} {k = linux;};
        };
        details = builtins.toJSON (lib.head result.failures).details;
      in
        kinds result == ["divergent"] && lib.all (value: lib.hasInfix (builtins.toJSON value) details) [darwin linux];
    in {
      list-order = diverges "list" ["a" "b"] ["b" "a"];
      object-whole = diverges "object" {a.b = 1;} {a.b = 2;};
      string = diverges "string" "darwin-value" "linux-value";
    };

    # `merge`, the `fix` paragraph: the divergent row pasted unedited is
    # refused naming both placeholder fields; filled in, merge is clean.
    repair = let
      pasted = run (divergent // {decisions = fixRows;});
      refused = builtins.toJSON (lib.findFirst (failure: failure.kind == "bad-decision") {} pasted.failures).details;
      edited = run (divergent // {decisions = lib.mapAttrs (_: row: row // decision row.combine) fixRows;});
    in {
      edited-clean = edited.failures == [];
      pasted-names-both = lib.all (field: lib.hasInfix field refused) ["decided" "reason"];
    };

    # Decisions table and `bad-decision`: one row for the string key `mode`,
    # differing from a valid row in the fields shown and refused.
    decisions = let
      verdict = key: fields:
        kinds (run {
          declarations.mode = static "string";
          decisions.${key} = decision "equal" // fields;
          raws = both {mode = "same";};
        })
        == ["bad-decision"];
      refuse = verdict "mode";
    in {
      # `and` on a string would otherwise throw inside the reducer.
      combine-and-on-string = refuse {combine = "and";};
      combine-max-on-string = refuse {combine = "max";};
      combine-unknown = refuse {combine = "average";};
      date-malformed = refuse {decided = "2026-1-01";};
      date-month-13 = refuse {decided = "2026-13-01";};
      date-placeholder = refuse {decided = "YYYY-MM-DD";};
      ignore-non-collection = refuse {ignore = ["x"];};
      reason-blank = refuse {reason = " ";};
      reason-todo = refuse {reason = "TODO";};
      reason-todo-colon = refuse {reason = "TODO:";};
      reason-todo-indented = refuse {reason = "  TODO: why";};
      undeclared-key = verdict "ghost" {};
    };

    # Decisions: `ignore` as a combine drops the key from the aggregate, so
    # differing raws are not divergent, yet its raws are still validated.
    # Columns: type, Darwin raw, Linux raw, failure kinds.
    ignoreCombine = let
      ignored = type: darwin: linux: expected: let
        result = run {
          declarations.k = static type;
          decisions.k = decision "ignore";
          raws = split darwin linux;
        };
      in
        kinds result == expected && !(result.aggregate ? k);
    in {
      declared-gone = ignored "count" {} {} ["declared-gone"];
      missing-system = ignored "count" {} {k = 5;} ["missing-system"];
      type-mismatch = ignored "count" {k = "five";} {k = "five";} ["type-mismatch"];
    };

    # `merge`, failure kinds: `declared-gone` (with its fix) and
    # `missing-system` name the absent declaration or required system.
    presence = let
      gone = run {
        declarations.lastRun = static "string";
        raws = both {};
      };
    in {
      declared-gone = kinds gone == ["declared-gone"] && (lib.head gone.failures).fix == "delete the declaration for `lastRun`";
      missing-system =
        kinds (run {
          declarations.limit = static "count";
          raws = split {} {limit = 5;};
        })
        == ["missing-system"];
    };

    # Declarations: `count` is a non-negative integer, `set` a list of
    # strings. The key is required on Linux only, so one raw is checked.
    # Columns: type, Linux raw, whether it fits.
    types = let
      fits = type: value: accepted:
        kinds (run {
          declarations.k = static type // {systems = ["x86_64-linux"];};
          raws = split {} {k = value;};
        })
        == lib.optional (!accepted) "type-mismatch";
    in {
      count-negative = fits "count" (-1) false;
      count-string = fits "count" "five" false;
      count-zero = fits "count" 0 true;
      set-non-string = fits "set" ["a" 1] false;
    };

    # Undeclared keys, and a raw leaf at a strict prefix of a declared path:
    # listed in `undeclared`, a failure only when credential-shaped.
    # Columns: declared key, raw tree, undeclared, failure kinds.
    undeclared = let
      loose = key: tree: listed: expected: let
        result = run {
          declarations.${key} = static "string";
          raws = both tree;
        };
      in
        result.undeclared == listed && kinds result == expected;
    in {
      plain = loose "mode" {
        mode = "same";
        newThing = "value";
      } ["newThing"] [];
      prefix-leaf = loose "apiToken.child" {apiToken = "credential";} ["apiToken"] ["declared-gone" "undeclared-secret"];
      secret = loose "mode" {
        apiToken = "value";
        mode = "same";
      } ["apiToken"] ["undeclared-secret"];
    };

    # `load`. ./load/all-present holds both configured raws, a raw for a
    # system config/systems.nix does not list (never read) and a decision
    # the differing raws need. ./load/absent-system lacks the Darwin raw and
    # keeps a `prefer:aarch64-darwin` decision.
    load = let
      all = load {dir = ./load/all-present;};
      absent = load {dir = ./load/absent-system;};
      once = load {dir = ./load/measured-once;};
    in {
      absent-system-fails =
        absent.systems
        == ["x86_64-linux"]
        && absent.failures
        == map (key: {
          inherit key;
          details = ["aarch64-darwin"];
          fix = "extract `${key}` on aarch64-darwin, or narrow its declared `systems`";
          kind = "missing-system";
        }) ["limit" "mode"];
      all-present = all.systems == systems && all.failures == [] && all.aggregate.limit.combine == "per-platform";
      measured-once = once.systems == ["x86_64-linux"] && once.failures == [] && get once.aggregate "limit" == 5;
      missing-facts-throws = !(builtins.tryEval (load {dir = ./.;})).success;
    };

    # `get` refuses a `per-platform` key, which has no combined value; `get`
    # on a divergent key throws, carrying merge's own failure (its message is
    # asserted in extracted-facts-divergent-fix).
    platform = let
      result = run {
        declarations.limit = static "count";
        decisions.limit = decision "per-platform";
        raws = split {limit = 3;} {limit = 5;};
      };
      diverged = run divergent;
    in {
      get-absent-throws = !(builtins.tryEval (get diverged.aggregate "gone")).success;
      get-divergent-throws = !(builtins.tryEval (get diverged.aggregate "mode")).success && diverged.aggregate.mode.failure == builtins.removeAttrs (lib.head diverged.failures) ["key"];
      get-throws = !(builtins.tryEval (get result.aggregate "limit")).success;
      no-value = kinds result == [] && !(result.aggregate.limit ? value);
    };

    # `expect`: a need is met, or fails naming consumer, key, expected and
    # actual value.
    expectations = let
      consumer = "delegate-routing";
      inherit
        (run {
          declarations = {
            "steering.maxChars" = static "count";
            tools = static "set";
          };
          raws = both {
            steering.maxChars = 50000;
            tools = ["invoke_sub_agent" "read"];
          };
        })
        aggregate
        ;
      failures = needs: (expect {inherit aggregate consumer needs;}).failures;
      # Every need is checked: one failure per unmet need, with its actual.
      misses = needs: seen:
        failures needs
        == lib.zipListsWith (need: actual: {
          inherit actual consumer;
          inherit (need) key;
          expected = builtins.removeAttrs need ["key"];
          kind = "expectation";
        })
        needs
        seen;
    in {
      all-met =
        failures [
          {
            contains = "invoke_sub_agent";
            key = "tools";
          }
        ]
        == [];
      contains-and-value-unmet = misses [
        {
          contains = "write";
          key = "tools";
        }
        {
          key = "steering.maxChars";
          value = 1;
        }
      ] [["invoke_sub_agent" "read"] 50000];
      presence-unmet = misses [{key = "absent";}] [null];
    };

    # Keys and the not-failures paragraph: a wildcard covers every child,
    # new or disappearing; the aggregate is keyed by concrete path.
    wildcards = let
      state = raws: decisions:
        run {
          declarations."features.<name>.state" = static "string";
          inherit decisions raws;
        };
      disappearing = split {
        features = {
          new.state = "on";
          old.state = "off";
        };
      } {features.old.state = "off";};
      covered = state (both {
        features = {
          new.state = "off";
          old.state = "on";
        };
      }) {};
      gone = state disappearing {};
      emptied = state (both {features = {};}) {};
    in {
      covers-every-child = covered.failures == [] && covered.undeclared == [] && get covered.aggregate "features.new.state" == "off" && get covered.aggregate "features.old.state" == "on";
      disappearing-child = gone.failures == [] && builtins.attrNames gone.aggregate."features.new.state".bySystem == ["aarch64-darwin"] && get gone.aggregate "features.new.state" == "on";
      emptied-parent = emptied.failures == [] && emptied.aggregate == {};
    };
  };
  failures = lib.concatLists (lib.mapAttrsToList (group: rows: map (row: "${group}.${row}") (builtins.attrNames (lib.filterAttrs (_: passed: !passed) rows))) groups);

  # `index`: one owner's merged aggregate, written per owner and indexed.
  indexed = index {
    demo = run {
      declarations.limit = static "count";
      raws = both {limit = 5;};
    };
  };
  # facts.nix and what it imports, for the evaluator in divergent-fix.
  source = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [../../lib/extracted/facts.nix ../../lib/runtime-values];
  };
  vocabulary = ["and" "equal" "ignore" "intersection" "max" "min" "or" "per-platform" "union"] ++ map (system: "prefer:${system}") systems;
in {
  checks = {
    extracted-facts = harness.mkTest "extracted-facts" (
      assert lib.assertMsg (failures == []) (builtins.toJSON failures); true
    );
    extracted-facts-index = pkgs.runCommand "extracted-facts-index" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      test -f ${indexed}/demo.json
      test -f ${indexed}/index.json
      ${pkgs.jq}/bin/jq -e '.demo.limit.value == 5' ${indexed}/index.json > /dev/null || {
        echo "FAIL: index.json does not carry the merged value of demo's limit" >&2
        exit 1
      }
      echo "PASS: extracted-facts-index" > "$out"
    '';
    # `merge`, the `fix` paragraph: the divergent fix is a complete
    # decisions.json object, wrapped by the declared pattern, and `get` on
    # the divergent key fails evaluation printing the key and that row.
    # tryEval cannot see a throw's message, so a dummy-store evaluator reads it.
    extracted-facts-divergent-fix = pkgs.runCommand "extracted-facts-divergent-fix" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      fix=${pkgs.writeText "divergent-fix.json" fixText}
      export HOME="$TMPDIR"
      if ${pkgs.nix}/bin/nix-instantiate --eval --strict --store dummy:// --expr ${lib.escapeShellArg ''
        let
          facts = import ${source}/lib/extracted/facts.nix {lib = import ${pkgs.path}/lib;};
        in
          facts.get (facts.merge (builtins.fromJSON ${builtins.toJSON (builtins.toJSON (divergent // {inherit systems;}))})).aggregate "mode"
      ''} 2> get.err; then
        echo "FAIL: get on the divergent key mode did not fail evaluation" >&2
        exit 1
      fi
      for fragment in '`mode`' "$(cat "$fix")"; do
        grep -qF -- "$fragment" get.err || {
          echo "FAIL: get's error does not name $fragment:" >&2
          cat get.err >&2
          exit 1
        }
      done
      ${pkgs.jq}/bin/jq -e --argjson vocabulary '${builtins.toJSON vocabulary}' '
        keys == ["mode"]
        and (.mode.combine | IN($vocabulary[]))
        and (.mode.reason | type == "string" and (trim | . == "TODO" or startswith("TODO:")))
        and .mode.decided == "YYYY-MM-DD"
      ' "$fix" > /dev/null || {
        echo "FAIL: divergent fix is not a complete decisions.json row:" >&2
        cat "$fix" >&2
        exit 1
      }
      echo "PASS: extracted-facts-divergent-fix" > "$out"
    '';
  };
}
