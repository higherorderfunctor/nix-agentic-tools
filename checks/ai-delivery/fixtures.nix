# A real evalModules fixture with the historical Shape A bug. Presence in the
# populated config is a positive control; the empty config must be rejected.
{
  lib,
  pkgs,
}: let
  policy = import ../../config/ai-delivery.nix {inherit lib;};
  schema = import ../../lib/ai/delivery-options.nix {inherit lib;};
  adapterLib = lib // {hm.dag = import ../../lib/hm-dag.nix {inherit lib;};};
  adapters = import ../../lib/ai/adapters {
    lib = adapterLib;
    inherit pkgs;
  };
  # The declaration owns the name. No fixture guesses a production writer's
  # attribute or changes a production policy row to simulate broken delivery.
  entry = {
    devenv = "ai:fixture:write";
    hm = "fixtureWrite";
  };
  writer = {
    ecosystem = "kiro";
    mode = "hm";
    primitive = "ownLeaves";
    probe = {
      base = {};
      option = ["ai" "kiro" "mcpServers"];
      nonEmpty.ai.kiro.mcpServers.probe.command = "true";
      empty.ai.kiro.mcpServers = {};
    };
    pruneTrigger = "Fixture writer exercises the real delivery gate.";
    surface = "mcpServers";
    target = "$HOME/.kiro/fixture.json";
    writerAttr = ["home" "activation" entry.hm];
  };
  exempted =
    writer
    // {
      exemption = {
        evidence = "checks/ai-delivery/fixtures.nix";
        reason = "Fixture exemption: the gate must record this failure rather than fail on it.";
      };
    };
  attested =
    writer
    // {
      absentWriter = {
        evidence = "checks/ai-delivery/fixtures.nix";
        reason = "Fixture record: this row's declared attribute does not exist yet.";
      };
    };
  independent =
    writer
    // {
      declarationIndependent = "Fixture claim: this writer's body cannot vary with the declaration.";
    };
  # `constant` freezes the body so it cannot vary with the declaration: the
  # positive control for the third arm. The default body embeds the pool, as a
  # real writer's does, so the unconditional control still passes all three.
  evaluatorsFor = {
    constant,
    gated,
    missing ? false,
  }:
    lib.genAttrs policy.modes (backend: declaration:
      (lib.evalModules {
        modules = [
          ({
            config,
            options,
            ...
          }: let
            cfg = config.ai.kiro;
            pool = lib.getAttrFromPath writer.probe.option config;
            attrs = lib.mkOption {
              type = lib.types.attrsOf lib.types.anything;
              default = {};
            };
          in {
            options = {
              ai.kiro = {
                _ownPlans = attrs;
                activation = lib.mkOption {
                  type = schema.writerMapType;
                  default = {};
                };
                enable = lib.mkEnableOption "fixture";
                files = lib.mkOption {
                  type = schema.fileMapType;
                  default = {};
                };
                mcpServers = attrs;
                methodFor = lib.mkOption {default = args: args.default args;};
              };
              assertions = lib.mkOption {
                type = lib.types.listOf lib.types.anything;
                default = [];
              };
              home = attrs;
              files = attrs;
              tasks = attrs;
              enterTest = lib.mkOption {
                type = lib.types.lines;
                default = "";
              };
            };
            config = lib.mkMerge [
              {
                ai.kiro.activation.fixture = lib.mkIf (!missing && (!gated || pool != {})) {
                  inherit entry;
                  command =
                    "printf '%s' "
                    + lib.escapeShellArg (
                      "fixture writer" + lib.optionalString (!constant) (builtins.toJSON pool)
                    );
                };
              }
              (adapters.${backend} {
                inherit cfg config options;
                runtime = "kiro";
              })
            ];
          })
          {config = declaration;}
        ];
      }).config);
  # The gate takes its evaluators as an argument so a control can wrap them:
  # the malformed-body and failed-assertion controls override what the fixture
  # module produced, which is a shape no declaration can express.
  inspect = {
    evaluators,
    writers ? [writer],
  }:
    import ./gate.nix {inherit lib;} {
      policy = policy // {imperativeWriters = writers;};
      inherit evaluators;
    };
  gateOf = {
    constant ? false,
    gated ? false,
    missing ? false,
    writers ? [writer],
  }:
    inspect {
      inherit writers;
      evaluators = evaluatorsFor {inherit constant gated missing;};
    };
  gate = gated: gateOf {inherit gated;};
  overriding = {
    override,
    writers ? [writer],
  }:
    inspect {
      inherit writers;
      evaluators =
        lib.mapAttrs (_: evaluate: declaration: (evaluate declaration) // override)
        (evaluatorsFor {
          constant = false;
          gated = false;
        });
    };
  # Replacing the writer's own attribute is the positive control for the body
  # accessor: an absent, empty, whitespace-only or wrongly-typed body must read
  # as absent rather than as a default the accessor invented.
  malformedWriter = entry: overriding {override = lib.setAttrByPath writer.writerAttr entry;};
  # The same absence, EXEMPTED. An exemption buys the empty-arm and
  # identical-body failures; it must not buy a writerAttr that resolves to
  # nothing, because then the gate is excusing an observation it never made.
  exemptedAbsent = gateOf {
    missing = true;
    writers = [exempted];
  };
  attestedAbsent = gateOf {
    missing = true;
    writers = [attested];
  };
  attestedPresent = gateOf {writers = [attested];};
  rejectedAssertion = overriding {
    override = {
      assertions = [
        {
          assertion = false;
          message = "fixture assertion control";
        }
      ];
    };
  };
  # A writer that emits the same body whether or not the pool is populated.
  constant = gateOf {constant = true;};
  # An exempted writer that still fails records; one that has started passing
  # every arm is itself the error, which is what forces the exemption's removal.
  recorded = gateOf {
    gated = true;
    writers = [exempted];
  };
  stale = gateOf {writers = [exempted];};
  # The declaration-independent claim is checked in both directions: a constant
  # body upholds it, a varying body refutes it.
  independentConstant = gateOf {
    constant = true;
    writers = [independent];
  };
  independentVarying = gateOf {writers = [independent];};
  rejects = rows: !(builtins.tryEval (builtins.deepSeq (policy.validateRows rows) true)).success;
  first = builtins.head policy.rows;
  rest = builtins.tail policy.rows;
  replaceFirst = fields: [(first // fields)] ++ rest;
  # Schema controls remain independent: generated data must still satisfy the
  # public policy schema. Malformed sink records below deliberately test the
  # gate's body accessor, since typed delivery entries cannot emit those shapes.
  schemaControls =
    {
      blank-absence-evidence = replaceFirst {absentWriter.evidence = "";};
      blank-absence-reason = replaceFirst {
        absentWriter = {
          evidence = "probe";
          reason = "";
        };
      };
      blank-constant-evidence = replaceFirst {constantGate = "";};
      blank-independent-reason = replaceFirst {declarationIndependent = "";};
      dotted-input = replaceFirst {inputOptions = ["ai.rules"];};
      doubled-absence = replaceFirst {
        absentWriter = {
          evidence = "probe";
          reason = "probe";
        };
        exemption = {
          evidence = "probe";
          reason = "probe";
        };
      };
      duplicate = policy.rows ++ [first];
      empty-input = replaceFirst {inputOptions = [[]];};
      missing-mode = rest;
      unexplained-gap = replaceFirst {
        primitive = "notApplicable";
        target = null;
        writerAttr = [];
        reason = "";
      };
      unknown-primitive = replaceFirst {primitive = "typo";};
      untested-additional = replaceFirst {additionalWriters = [(builtins.removeAttrs writer ["probe"])];};
      upstream-command = replaceFirst {
        primitive = "upstream";
        target = "probe";
        writerAttr = ["probe"];
        reason = "delegation";
        reverifyCommand = "";
      };
      upstream-reason = replaceFirst {
        primitive = "upstream";
        target = "probe";
        writerAttr = ["probe"];
        reason = "";
        reverifyCommand = "true";
      };
    }
    // lib.genAttrs ["ecosystem" "mode" "primitive" "pruneTrigger" "surface" "target" "writerAttr"]
    (field: [(builtins.removeAttrs first [field])] ++ rest);
  malformedControls = {
    absent-body = {};
    empty-body = {text = "";};
    null-body = {text = null;};
    number-body = {text = 42;};
    whitespace-body = {text = " \n\t";};
    wrong-backend = {exec = "wrong backend field";};
  };
  controls =
    lib.mapAttrs (_: rows: {passed = builtins.deepSeq (policy.validateRows rows) true;}) schemaControls
    // lib.mapAttrs (_: malformedWriter) malformedControls
    // {
      absent = gateOf {missing = true;};
      assertion = rejectedAssertion;
      inherit constant;
      exempted-absent = exemptedAbsent;
      gated = gate true;
      independent-varying = independentVarying;
      stale-absence = attestedPresent;
      stale-exemption = stale;
    };
in {
  inherit controls;
  broken = gate true;
  valid = gate false;
  passed = assert lib.assertMsg (lib.all (control: !(builtins.tryEval control.passed).success) (builtins.attrValues controls))
  "ai-delivery fixture: a negative control passed";
  assert lib.assertMsg (lib.all (backend: let
    backendWriter =
      writer
      // {
        mode = backend;
        writerAttr =
          (
            if backend == "hm"
            then ["home" "activation"]
            else ["tasks"]
          )
          ++ [entry.${backend}];
      };
    good = gateOf {writers = [backendWriter];};
    bad = gateOf {
      gated = true;
      writers = [backendWriter];
    };
  in
    good.passed && !(builtins.tryEval bad.passed).success)
  policy.modes)
  "ai-delivery fixture: real adapters must expose a gated writer on both backends";
  assert lib.assertMsg (gate false).passed "ai-delivery fixture: unconditional writer rejected";
  assert lib.assertMsg (!(builtins.tryEval (gate true).passed).success) "ai-delivery fixture: gated writer accepted";
  assert lib.assertMsg (
    !(builtins.tryEval rejectedAssertion.passed).success
    && builtins.length rejectedAssertion.errors == 2
    && lib.all (lib.hasInfix "fixture assertion control") rejectedAssertion.errors
  ) "ai-delivery fixture: evaluator assertion failure ignored";
  assert lib.assertMsg (lib.all (entry: let
    result = malformedWriter entry;
  in
    !(builtins.tryEval result.passed).success && builtins.length result.errors == 2) (builtins.attrValues malformedControls)) "ai-delivery fixture: missing, empty, or malformed writer body accepted";
  assert lib.assertMsg (builtins.length (gate true).errors == 1 && lib.hasInfix "EMPTY declaration" (builtins.head (gate true).errors)) "ai-delivery fixture: rejection must be the empty writer, not an unrelated error";
  assert lib.assertMsg (!(builtins.tryEval constant.passed).success) "ai-delivery fixture: constant-bodied writer accepted";
  assert lib.assertMsg (builtins.length constant.errors == 1 && lib.hasInfix "IDENTICAL" (builtins.head constant.errors)) "ai-delivery fixture: rejection must name the identical-body arm, not an unrelated error";
  assert lib.assertMsg independentConstant.passed "ai-delivery fixture: declaration-independent writer with a constant body rejected";
  assert lib.assertMsg (!(builtins.tryEval independentVarying.passed).success) "ai-delivery fixture: declaration-independent claim accepted for a body that varies";
  assert lib.assertMsg (builtins.length independentVarying.errors == 1 && lib.hasInfix "declared declaration-independent" (builtins.head independentVarying.errors)) "ai-delivery fixture: rejection must name the refuted declaration-independent claim";
  assert lib.assertMsg (recorded.passed
    && recorded.errors == []
    && builtins.length (builtins.head recorded.results).exempted == 1) "ai-delivery fixture: an exempted failure must be recorded, not fatal";
  assert lib.assertMsg (!(builtins.tryEval stale.passed).success) "ai-delivery fixture: stale exemption accepted";
  assert lib.assertMsg (builtins.length stale.errors == 1 && lib.hasInfix "exemption is stale" (builtins.head stale.errors)) "ai-delivery fixture: a writer that survives both arms must fail as a stale exemption";
  assert lib.assertMsg (
    !(builtins.tryEval exemptedAbsent.passed).success
    && builtins.length exemptedAbsent.errors == 1
    && lib.hasInfix "NON-EMPTY declaration" (builtins.head exemptedAbsent.errors)
    && builtins.length (builtins.head exemptedAbsent.results).exempted == 2
  ) "ai-delivery fixture: an exemption excused a writer that is absent under BOTH declarations";
  assert lib.assertMsg (attestedAbsent.passed
    && attestedAbsent.errors == []
    && builtins.length (builtins.head attestedAbsent.results).exempted == 2) "ai-delivery fixture: an attested-absent writer must record, not fail";
  assert lib.assertMsg (
    !(builtins.tryEval attestedPresent.passed).success
    && builtins.length attestedPresent.errors == 1
    && lib.hasInfix "absentWriter record is stale" (builtins.head attestedPresent.errors)
  ) "ai-delivery fixture: an absentWriter record survived the attribute appearing";
  assert lib.assertMsg (lib.all (name: rejects schemaControls.${name}) (builtins.attrNames schemaControls))
  "ai-delivery fixture: invalid policy schema accepted"; true;
}
