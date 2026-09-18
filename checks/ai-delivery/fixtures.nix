# A real evalModules fixture with the historical Shape A bug. Presence in the
# populated config is a positive control; the empty config must be rejected.
{lib}: let
  policy = import ../../config/ai-delivery.nix {inherit lib;};
  writer =
    lib.findFirst (row: row.surface == "mcpServers" && row.ecosystem == "kiro" && row.mode == "hm")
    (throw "fixture needs the Kiro HM MCP contract")
    policy.imperativeWriters;
  fixturePolicy = policy // {imperativeWriters = [writer];};
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
  gate = gated:
    import ./gate.nix {inherit lib;} {
      policy = fixturePolicy;
      evaluators = evaluatorsFor gated;
    };
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
