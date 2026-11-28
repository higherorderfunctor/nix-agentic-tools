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
  inherit (harness) checkRows mkTest;
  inherit (import ../../lib/extracted/facts.nix {inherit lib;}) children expect get load merge;
  inherit (import ../../lib/extracted {inherit pkgs;}) index;
  runner = (import ./runner.nix {inherit lib pkgs;}).nix;
  platforms = import ../../lib/extracted/platforms.nix;
  systems = import configSystems;
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
    # `children`: exact wildcard leaves, filtering by depth and fixed
    # segments, and a parent with no matching children. The diagnostics
    # below test refusal of a child that must be read per system.
    children = let
      pattern = "features.<name>.state";
      input = {
        declarations = {
          "features.<name>.state" = static "string";
          "features.unrelated.status" = static "string";
          "other.features.nested.state" = static "string";
        };
        raws = both {
          features = {
            new.state = "on";
            old.state = "off";
            unrelated.status = "different leaf";
          };
          other.features.nested.state = "different depth";
        };
      };
      matched = run input;
      empty = run {
        declarations.${pattern} = static "string";
        raws = both {features = {};};
      };
    in {
      empty = children empty.aggregate pattern == {};
      matches-two =
        children matched.aggregate pattern
        == {
          new = "on";
          old = "off";
        };
    };

    # Decisions: the combine vocabulary and the defaults table. A key `k`
    # differs (or not) across systems; columns: combine, type, Darwin raw,
    # Linux raw, combined value. Sets must have exactly the listed members
    # with no duplicates; only lists require their order to be preserved.
    combines = let
      combined = written: combine: type: darwin: linux: value: let
        result = run ({
            declarations.k = static type;
            raws = split {k = darwin;} {k = linux;};
          }
          // lib.optionalAttrs written {decisions.k = decision combine;});
        actual = get result.aggregate "k";
        expected =
          if type == "set"
          then builtins.length actual == builtins.length value && lib.all (member: builtins.elem member actual) value
          else actual == value;
      in
        kinds result == [] && result.aggregate.k.combine == combine && expected;
      byDefault = combined false;
      decided = combined true;
    in {
      bool-and = byDefault "and" "bool" true false false;
      bool-or = decided "or" "bool" true false true;
      count-max = decided "max" "count" 3 5 5;
      count-min = decided "min" "count" 3 5 3;
      list-agree = byDefault "equal" "list" ["b" "a"] ["b" "a"] ["b" "a"];
      object-agree = byDefault "equal" "object" {a.b = 1;} {a.b = 1;} {a.b = 1;};
      set-intersection = byDefault "intersection" "set" ["a" "b"] ["c" "b"] ["b"];
      set-union = decided "union" "set" ["b" "a" "a"] ["c" "b"] ["a" "b" "c"];
      string-prefer = decided "prefer:x86_64-linux" "string" "darwin-value" "linux-value" "linux-value";
    };

    # `merge`, failure kinds: `divergent` under an effective `equal`, with
    # every system's value in `details`. Columns: type, Darwin raw, Linux raw.
    divergence = let
      diverges = type: darwin: linux: let
        result = run {
          declarations.k = static type;
          raws = split {k = darwin;} {k = linux;};
        };
      in
        map (failure: {inherit (failure) details key kind;}) result.failures
        == [
          {
            details = split darwin linux;
            key = "k";
            kind = "divergent";
          }
        ];
    in {
      list-order = diverges "list" ["a" "b"] ["b" "a"];
      object-whole = diverges "object" {a.b = 1;} {a.b = 2;};
    };

    # `merge`, the `fix` paragraph: the divergent row pasted unedited is
    # refused naming both placeholder fields; filled in, merge is clean.
    repair = let
      pasted = run (divergent // {decisions = fixRows;});
      edited = run (divergent // {decisions.mode = fixRows.mode // decision fixRows.mode.combine;});
    in {
      edited-clean = edited.failures == [] && (edited.aggregate.mode.bySystem or null) == split "darwin-value" "linux-value";
      pasted-names-both =
        map (failure: {
          inherit (failure) key kind;
          details =
            if failure.kind == "bad-decision"
            then lib.sort builtins.lessThan failure.details
            else failure.details;
        })
        pasted.failures
        == [
          # Validation discards the pasted row, so the original disagreement remains.
          {
            details = split "darwin-value" "linux-value";
            key = "mode";
            kind = "divergent";
          }
          {
            details = ["decided must be an ISO date (YYYY-MM-DD)" "reason must be non-blank and not a TODO placeholder"];
            key = "mode";
            kind = "bad-decision";
          }
        ];
    };

    # Decisions table and `bad-decision`: one row for the string key `mode`,
    # differing from a valid row in the fields shown, accepted or refused.
    decisions = let
      verdict = key: fields: details: let
        result = run {
          declarations.mode = static "string";
          decisions.${key} = decision "equal" // fields;
          raws = both {mode = "same";};
        };
      in
        map (failure: {inherit (failure) details key kind;}) result.failures
        == lib.optional (details != []) {
          inherit details key;
          kind = "bad-decision";
        };
      accept = fields: verdict "mode" fields [];
      refuse = fields: detail: verdict "mode" fields [detail];
      invalidDate = value: refuse {decided = value;} "decided must be an ISO date (YYYY-MM-DD)";
      invalidReason = value: refuse {reason = value;} "reason must be non-blank and not a TODO placeholder";
    in {
      # `and` on a string would otherwise throw inside the reducer.
      combine-and-on-string = refuse {combine = "and";} ''combine and does not apply to type "string"'';
      combine-max-on-string = refuse {combine = "max";} ''combine max does not apply to type "string"'';
      combine-unknown = refuse {combine = "average";} ''unknown combine "average"'';
      date-malformed = invalidDate "2026-1-01";
      date-month-13 = invalidDate "2026-13-01";
      # Calendar validity is not checked: the field is provenance.
      date-well-formed = accept {decided = "2026-02-31";};
      ignore-non-collection = refuse {ignore = ["x"];} "ignore needs a list on a set or list key";
      reason-blank = invalidReason " ";
      reason-todo = invalidReason "TODO";
      reason-todo-colon = invalidReason "TODO:";
      reason-todo-indented = invalidReason "  TODO: why";
      reason-todo-prefixed-word = accept {reason = "TODO entries are excluded because they are not implemented commands";};
      undeclared-key = verdict "ghost" {} ["row for an undeclared key"];
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
      drops-count = ignored "count" {k = 3;} {k = 5;} [];
      missing-system = ignored "count" {} {k = 5;} ["missing-system"];
      type-mismatch = ignored "count" {k = "five";} {k = "five";} ["type-mismatch"];
    };

    # An ignored member stays out even if every system measures it.
    ignoreElements.filters-shared-member =
      get
      (run {
        declarations.models = static "set";
        decisions.models = decision "intersection" // {ignore = ["preview"];};
        raws = split {models = ["a" "darwin" "preview"];} {models = ["a" "linux" "preview"];};
      }).aggregate "models"
      == ["a"];

    # `merge`: `declared-gone` gives a fix; a `live` key with `systems = []`
    # requires nothing.
    presence = let
      gone = run {
        declarations.lastRun = static "string";
        raws = both {};
      };
    in {
      declared-gone = kinds gone == ["declared-gone"] && (lib.head gone.failures).fix == "delete the declaration for `lastRun`";
      live-no-systems =
        (run {
          declarations.lastRun = {
            source = "live";
            systems = [];
            type = "string";
          };
          raws = both {};
        }).failures
        == [];
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
    };

    # `load`. ./load/all-present forks a key across both configured systems
    # and one config/systems.nix does not list (never read), with the
    # decision the differing values need. In ./load/absent-system Darwin's
    # side lacks every key, and a `prefer:aarch64-darwin` decision stays
    # valid. ./load/carried is a committed file with a fork, carried forward
    # by a fresh Linux raw that adds a feature (the update that once left
    # Kiro's aggregate failing evaluation, PR #2559).
    load = let
      absent = load {dir = ./load/absent-system;};
      all = load {dir = ./load/all-present;};
      carriedDir = ./load/carried;
      prior = load {dir = carriedDir;};
      read = file: builtins.fromJSON (builtins.readFile (carriedDir + "/${file}"));
      carried = platforms.carry {
        fresh.x86_64-linux = {
          features = ["new" "old"];
          patchability = {
            new = {
              patchable = true;
              unmatchedSites = 0;
            };
            old = {
              patchable = false;
              unmatchedSites = 1;
            };
          };
        };
        merged = read "extracted.json";
        inherit systems;
      };
      carriedLoad = merge {
        declarations = read "facts.json";
        decisions = read "decisions.json";
        raws = lib.genAttrs systems (platforms.project carried);
        inherit systems;
      };
      darwin = platforms.project carried "aarch64-darwin";
      # Replacing only Linux's side, as the per-system files did.
      replaced = merge {
        declarations = read "facts.json";
        decisions = read "decisions.json";
        raws = {
          aarch64-darwin = platforms.project (read "extracted.json") "aarch64-darwin";
          x86_64-linux = platforms.project carried "x86_64-linux";
        };
        inherit systems;
      };
    in {
      absent-system-fails =
        absent.failures
        == map (key: {
          inherit key;
          details = ["aarch64-darwin"];
          fix = "extract `${key}` on aarch64-darwin, or narrow its declared `systems`";
          kind = "missing-system";
        }) ["limit" "mode"];
      all-present =
        all.failures
        == []
        && builtins.attrNames all.aggregate == ["limit"]
        && all.aggregate.limit.combine == "per-platform"
        && all.aggregate.limit.bySystem == split 3 5;
      # The committed fixture must load both legs before carry changes either.
      carried-committed-loads =
        prior.failures
        == []
        && get prior.aggregate "features" == ["old"]
        && prior.aggregate."patchability.old.unmatchedSites".bySystem == split 2 1;
      carried-darwin-follows = darwin.patchability.new.unmatchedSites == 0 && darwin.patchability.old.unmatchedSites == 2;
      carried-loads = carriedLoad.failures == [] && get carriedLoad.aggregate "features" == ["new" "old"];
      replaced-diverges =
        map (failure: {inherit (failure) details key kind;}) replaced.failures
        == [
          {
            details = split ["old"] ["new" "old"];
            key = "features";
            kind = "divergent";
          }
        ];
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
    in {
      contains-and-value-unmet =
        failures [
          {
            contains = "write";
            key = "tools";
          }
          {
            key = "steering.maxChars";
            value = 1;
          }
        ]
        == [
          {
            actual = ["invoke_sub_agent" "read"];
            consumer = "delegate-routing";
            expected.contains = "write";
            key = "tools";
            kind = "expectation";
          }
          {
            actual = 50000;
            consumer = "delegate-routing";
            expected.value = 1;
            key = "steering.maxChars";
            kind = "expectation";
          }
        ];
      presence-unmet =
        failures [{key = "absent";}]
        == [
          {
            actual = null;
            consumer = "delegate-routing";
            expected = {};
            key = "absent";
            kind = "expectation";
          }
        ];
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
      preferred = state disappearing {"features.<name>.state" = decision "prefer:x86_64-linux";};
    in {
      covers-every-child = covered.failures == [] && covered.undeclared == [] && get covered.aggregate "features.new.state" == "off" && get covered.aggregate "features.old.state" == "on";
      disappearing-child = gone.failures == [] && builtins.attrNames gone.aggregate."features.new.state".bySystem == ["aarch64-darwin"] && get gone.aggregate "features.new.state" == "on";
      emptied-parent = emptied.failures == [] && emptied.aggregate == {};
      prefer-sole-value = preferred.failures == [] && get preferred.aggregate "features.new.state" == "on";
    };
  };

  # `index`: one owner's merged aggregate, written per owner and indexed.
  indexed = index {
    demo = run {
      declarations.limit = static "count";
      raws = both {limit = 5;};
    };
  };
  # facts.nix and what it imports, plus the load fixtures needed by the
  # dummy-store evaluator. Path resolution is part of the load check.
  source = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [./load configSystems ../../lib/extracted/facts.nix ../../lib/extracted/platforms.nix ../../lib/open-keys ../../lib/redact/classify.nix];
  };
  configSystems = ../../config/systems.nix;
  diagnostics = {
    children-multiple-wildcards = {
      expr = ''facts.children all.aggregate "<name>.<name>.state"'';
      names = ["`<name>.<name>.state` must contain exactly one <name> segment"];
    };
    children-no-wildcard = {
      expr = ''facts.children all.aggregate "features.old.state"'';
      names = ["`features.old.state` must contain exactly one <name> segment"];
    };
    children-per-platform = {
      expr = ''facts.children carried.aggregate "patchability.<name>.unmatchedSites"'';
      names = ["`patchability.old.unmatchedSites` has no combined value (per-platform)"];
    };
    get-absent = {
      expr = ''facts.get all.aggregate "gone"'';
      names = ["`gone` is not in the aggregate"];
    };
    get-divergent = {
      expr = ''facts.get (facts.merge (builtins.fromJSON ${builtins.toJSON (builtins.toJSON (divergent // {inherit systems;}))})).aggregate "mode"'';
      names = ["`mode` has no combined value (divergent)" ''"aarch64-darwin":"darwin-value"'' ''"x86_64-linux":"linux-value"'' fixText];
    };
    get-per-platform = {
      expr = ''facts.get all.aggregate "limit"'';
      names = ["`limit` has no combined value (per-platform)" "read bySystem from the index"];
    };
    load-missing-facts = {
      expr = ''facts.load {dir = ${source}/checks/extracted/load;}'';
      names = ["/load/facts.json is missing"];
    };
    load-unmeasured = {
      expr = ''facts.load {dir = ${source}/checks/extracted/load/unmeasured;}'';
      names = ["/unmeasured/extracted.json is missing"];
    };
  };
  runDiagnostic = label: case:
    runner {
      inherit label;
      inherit (case) names;
      expr = ''
        let
          facts = import ${source}/lib/extracted/facts.nix {lib = import ${pkgs.path}/lib;};
          all = facts.load {dir = ${source}/checks/extracted/load/all-present;};
          carried = facts.load {dir = ${source}/checks/extracted/load/carried;};
        in ${case.expr}
      '';
    };
in {
  checks = {
    extracted-facts = mkTest "extracted-facts" (
      checkRows "extracted-facts" (lib.concatMapAttrs (group: rows:
        lib.mapAttrs' (row: lib.nameValuePair "${group}.${row}") rows)
      groups)
    );
    extracted-facts-index = pkgs.runCommand "extracted-facts-index" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      check_index() {
        local file=$1 expectation=$2 filter=$3
        ${pkgs.jq}/bin/jq -e "$filter" "${indexed}/$file" > /dev/null || {
          printf 'FAIL: %s must contain %s\n' "$file" "$expectation" >&2
          if [ -f "${indexed}/$file" ]; then cat "${indexed}/$file" >&2; fi
          exit 1
        }
      }
      check_index demo.json 'only limit, with value 5' 'keys == ["limit"] and .limit.value == 5'
      check_index index.json 'only demo, with only limit and its value 5' 'keys == ["demo"] and (.demo | keys == ["limit"]) and .demo.limit.value == 5'
      echo "PASS: extracted-facts-index" > "$out"
    '';
    # The complete decisions.json fix and exact diagnostics from the
    # public load, children and get entry points.
    extracted-facts-divergent-fix = pkgs.runCommand "extracted-facts-divergent-fix" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      fix=${pkgs.writeText "divergent-fix.json" fixText}
      ${lib.concatStrings (lib.mapAttrsToList runDiagnostic diagnostics)}
      ${pkgs.jq}/bin/jq -e '
        (.mode | keys == ["combine", "decided", "reason"])
        and (.mode.reason | type == "string" and (trim | startswith("TODO:") and length > 5))
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
