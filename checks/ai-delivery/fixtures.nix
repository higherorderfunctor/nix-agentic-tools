# A real evalModules fixture with the historical Shape A bug. Presence in the
# populated config is a positive control; the empty config must be rejected.
{lib}: let
  policy = import ../../config/ai-delivery.nix {inherit lib;};
  # The production row carries an exemption until the ownership fix lands, so
  # the fixture strips it: proving the gate REJECTS a gated writer needs the
  # un-exempted shape, and the exemption controls re-attach their own.
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
  evaluatorsFor = gated:
    lib.genAttrs policy.modes (_: declaration:
      (lib.evalModules {
        modules = [
          ({config, ...}: {
            options = {
              ai = lib.mkOption {type = lib.types.attrsOf lib.types.anything;};
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
              lib.mkIf (!gated || lib.attrByPath writer.probe.option {} config != {})
              (lib.setAttrByPath writer.writerAttr {text = "fixture writer";});
          })
          {config = declaration;}
        ];
      }).config);
  gateOf = writers: gated:
    import ./gate.nix {inherit lib;} {
      policy = policy // {inherit (writers) imperativeWriters;};
      evaluators = evaluatorsFor gated;
    };
  gate = gateOf {imperativeWriters = [writer];};
  # An exempted writer that still fails records; one that has started passing
  # both arms is itself the error, which is what forces the exemption's removal.
  recorded = gateOf {imperativeWriters = [exempted];} true;
  stale = gateOf {imperativeWriters = [exempted];} false;
  rejects = rows: !(builtins.tryEval (builtins.deepSeq (policy.validateRows rows) true)).success;
  first = builtins.head policy.rows;
  rest = builtins.tail policy.rows;
  replaceFirst = fields: [(first // fields)] ++ rest;
in {
  broken = gate true;
  valid = gate false;
  passed = assert lib.assertMsg (gate false).passed "ai-delivery fixture: unconditional writer rejected";
  assert lib.assertMsg (!(builtins.tryEval (gate true).passed).success) "ai-delivery fixture: gated writer accepted";
  assert lib.assertMsg (builtins.length (gate true).errors == 1 && lib.hasInfix "EMPTY declaration" (builtins.head (gate true).errors)) "ai-delivery fixture: rejection must be the empty writer, not an unrelated error";
  assert lib.assertMsg (recorded.passed
    && recorded.errors == []
    && builtins.length (builtins.head recorded.results).exempted == 1) "ai-delivery fixture: an exempted failure must be recorded, not fatal";
  assert lib.assertMsg (!(builtins.tryEval stale.passed).success) "ai-delivery fixture: stale exemption accepted";
  assert lib.assertMsg (builtins.length stale.errors == 1 && lib.hasInfix "exemption is stale" (builtins.head stale.errors)) "ai-delivery fixture: a writer that survives both arms must fail as a stale exemption";
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
