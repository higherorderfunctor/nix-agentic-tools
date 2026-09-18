# A real evalModules fixture with the historical Shape A bug. Presence in the
# populated config is a positive control; the empty config must be rejected.
{lib}: let
  policy = import ../../config/ai-delivery.nix {inherit lib;};
  # Stripped so the fixture does not depend on whether the production row
  # happens to carry an exemption: proving the gate REJECTS a gated writer
  # needs the un-exempted shape, and the exemption controls attach their own.
  writer = builtins.removeAttrs (
    lib.findFirst (row: row.surface == "mcpServers" && row.ecosystem == "kiro" && row.mode == "hm")
    (throw "fixture needs the Kiro HM MCP contract")
    policy.imperativeWriters
  ) ["exemption"];
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
  }:
    lib.genAttrs policy.modes (_: declaration:
      (lib.evalModules {
        modules = [
          ({config, ...}: let
            # getAttrFromPath, not `attrByPath ... {}`: both probes set the pool
            # explicitly, so an absent path is a broken probe and must throw
            # rather than read as an empty pool.
            pool = lib.getAttrFromPath writer.probe.option config;
          in {
            options = {
              ai = lib.mkOption {type = lib.types.attrsOf lib.types.anything;};
              assertions = lib.mkOption {
                type = lib.types.listOf lib.types.anything;
                default = [];
              };
              home = lib.mkOption {
                type = lib.types.attrsOf lib.types.anything;
                default = {};
              };
              tasks = lib.mkOption {
                type = lib.types.attrsOf lib.types.anything;
                default = {};
              };
            };
            config =
              lib.mkIf (!gated || pool != {})
              (lib.setAttrByPath writer.writerAttr {
                text = "fixture writer" + lib.optionalString (!constant) (builtins.toJSON pool);
              });
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
    writers ? [writer],
  }:
    inspect {
      inherit writers;
      evaluators = evaluatorsFor {inherit constant gated;};
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
  exemptedAbsent = overriding {
    override = lib.setAttrByPath writer.writerAttr {};
    writers = [exempted];
  };
  # An attested-absent writer records instead of failing, and its countdown
  # runs the other way: the row errors as soon as the attribute exists.
  attestedAbsent = overriding {
    override = lib.setAttrByPath writer.writerAttr {};
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
in {
  broken = gate true;
  valid = gate false;
  passed = assert lib.assertMsg (gate false).passed "ai-delivery fixture: unconditional writer rejected";
  assert lib.assertMsg (!(builtins.tryEval (gate true).passed).success) "ai-delivery fixture: gated writer accepted";
  assert lib.assertMsg (
    !(builtins.tryEval rejectedAssertion.passed).success
    && builtins.length rejectedAssertion.errors == 2
    && lib.all (lib.hasInfix "fixture assertion control") rejectedAssertion.errors
  ) "ai-delivery fixture: evaluator assertion failure ignored";
  assert lib.assertMsg (lib.all (entry: let
    result = malformedWriter entry;
  in
    !(builtins.tryEval result.passed).success && builtins.length result.errors == 2) [
    {}
    {exec = "wrong backend field";}
    {text = "";}
    {text = " \n\t";}
    {text = null;}
    {text = 42;}
  ]) "ai-delivery fixture: missing, empty, or malformed writer body accepted";
  assert lib.assertMsg (builtins.length (gate true).errors == 1 && lib.hasInfix "EMPTY declaration" (builtins.head (gate true).errors)) "ai-delivery fixture: rejection must be the empty writer, not an unrelated error";
  assert lib.assertMsg (!(builtins.tryEval constant.passed).success) "ai-delivery fixture: constant-bodied writer accepted";
  assert lib.assertMsg (builtins.length constant.errors == 1 && lib.hasInfix "IDENTICAL" (builtins.head constant.errors)) "ai-delivery fixture: rejection must name the identical-body arm, not an unrelated error";
  assert lib.assertMsg independentConstant.passed "ai-delivery fixture: declaration-independent writer with a constant body rejected";
  assert lib.assertMsg (!(builtins.tryEval independentVarying.passed).success) "ai-delivery fixture: declaration-independent claim accepted for a body that varies";
  assert lib.assertMsg (builtins.length independentVarying.errors == 1 && lib.hasInfix "declared declaration-independent" (builtins.head independentVarying.errors)) "ai-delivery fixture: rejection must name the refuted declaration-independent claim";
  assert lib.assertMsg (rejects (replaceFirst {declarationIndependent = "";})) "ai-delivery fixture: blank declaration-independent reason accepted";
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
  assert lib.assertMsg (lib.all (fields: rejects (replaceFirst fields)) [
    {absentWriter.evidence = "";}
    {
      absentWriter = {
        evidence = "probe";
        reason = "";
      };
    }
    {
      absentWriter = {
        evidence = "probe";
        reason = "probe";
      };
      exemption = {
        evidence = "probe";
        reason = "probe";
      };
    }
  ]) "ai-delivery fixture: incomplete or doubled absence record accepted";
  assert lib.assertMsg (rejects (replaceFirst {constantGate = "";})) "ai-delivery fixture: blank constant-gate evidence accepted";
  assert lib.assertMsg (rejects (replaceFirst {inputOptions = ["ai.rules"];})) "ai-delivery fixture: dotted-string input option accepted";
  assert lib.assertMsg (rejects (replaceFirst {inputOptions = [[]];})) "ai-delivery fixture: empty input option path accepted";
  assert lib.assertMsg (lib.all (field: rejects ([(builtins.removeAttrs first [field])] ++ rest)) ["ecosystem" "mode" "primitive" "pruneTrigger" "surface" "target" "writerAttr"]) "ai-delivery fixture: missing required field accepted";
  assert lib.assertMsg (rejects rest) "ai-delivery fixture: missing mode accepted";
  assert lib.assertMsg (rejects (policy.rows ++ [first])) "ai-delivery fixture: duplicate accepted";
  assert lib.assertMsg (rejects (replaceFirst {primitive = "typo";})) "ai-delivery fixture: open primitive enum";
  assert lib.assertMsg (rejects (replaceFirst {
    primitive = "notApplicable";
    target = null;
    writerAttr = [];
    reason = "";
  })) "ai-delivery fixture: unexplained gap accepted";
  assert lib.assertMsg (rejects (replaceFirst {
    primitive = "upstream";
    target = "probe";
    writerAttr = ["probe"];
    reason = "delegation";
    reverifyCommand = "";
  })) "ai-delivery fixture: upstream without command accepted";
  assert lib.assertMsg (rejects (replaceFirst {
    primitive = "upstream";
    target = "probe";
    writerAttr = ["probe"];
    reason = "";
    reverifyCommand = "true";
  })) "ai-delivery fixture: upstream without reason accepted";
  assert lib.assertMsg (rejects (replaceFirst {
    additionalWriters = [(builtins.removeAttrs writer ["probe"])];
  })) "ai-delivery fixture: untested additional imperative writer accepted"; true;
}
