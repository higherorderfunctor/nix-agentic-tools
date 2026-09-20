# Owned-entry controls use real runtime modules so path arbitration and both
# adapters participate. Each broken declaration has an otherwise healthy twin.
{
  harness,
  lib,
}: let
  ledger = "documents/probe.json";
  path = ".kiro/probe.json";
  base.ai.kiro = {
    activation.probeDocument.ledgers.${ledger} = {
      codec = "json";
      inherit path;
    };
    enable = true;
    files.${path} = {
      content.value.probe = true;
      entry = "probeDocument";
      facts.harnessWrites = true;
      format = "json";
      inherit ledger;
    };
  };
  copy = destination: {
    ai.copilot = {
      activation.probeCopy = {
        ledgers."materialize/probe.manifest" = {
          codec = "dir";
          path = ".kiro";
        };
        pruneEntry.hm = "probeCopyPrune";
      };
      enable = true;
      files.${destination} = {
        content.text = "{}";
        entry = "probeCopy";
        ledger = "materialize/probe.manifest";
        method = "copy-ro";
      };
    };
  };
  cases = {
    conflicting-methods = {
      broken = copy path;
      healthy = copy ".kiro/copy.json";
      expected = [
        "ai: copilot, kiro all deliver `${path}`; a contested path needs one owner. Give one runtime a distinct path; only a shared AGENTS.md context target is arbitrated."
        "ai: `${path}` is delivered by different methods; one path has one owner and one method."
      ];
    };
    copy-ro-json-ledger = {
      broken.ai.kiro.files.${path}.method = "copy-ro";
      healthy.ai.kiro = {
        activation.probeDocument = {
          ledgers.${ledger} = {
            codec = lib.mkForce "dir";
            path = lib.mkForce ".kiro";
          };
          pruneEntry.hm = "probeDocumentPrune";
        };
        files.${path}.method = "copy-ro";
      };
      expected = [''ai.kiro.files."${path}" uses `copy-ro`, which requires a directory ledger; `${ledger}` has codec `json`. A document ledger reconciles leaves and cannot own a read-only copy.''];
    };
    document-format-mismatch = {
      broken.ai.kiro.files.${path}.format = lib.mkForce "toml";
      healthy = {};
      expected = [''ai.kiro.files."${path}" has format `toml`, but document ledger `${ledger}` uses codec `json`. The document format must match its ledger codec.''];
    };
    document-path-mismatch = {
      broken.ai.kiro.activation.probeDocument.ledgers.${ledger}.path = lib.mkForce ".kiro/elsewhere.json";
      healthy = {};
      expected = [''ai.kiro.files."${path}" claims document ledger `${ledger}` at `.kiro/elsewhere.json`. A document claimant must use its ledger's exact path.''];
    };
    shared-without-ledger = {
      broken.ai.kiro.files.${path}.ledger = lib.mkForce null;
      healthy = {};
      expected = [
        ''
          ai.kiro.files."${path}" is delivered as `shared`, so it
          needs the writer that materializes it and the ledger that claims it:
          set `entry` and `ledger`, and declare both under
          ai.kiro.activation.
        ''
      ];
    };
    undeclared-writer = {
      broken.ai.kiro.files.${path}.entry = lib.mkForce "probeAbsent";
      healthy = {};
      expected = [
        ''
          ai.kiro.files."${path}" is materialized by writer
          `probeAbsent`, which ai.kiro.activation does not declare.
          Nothing writes this file, and nothing retracts it either.
        ''
      ];
    };
  };
  evaluate = backend: overlay: let
    cfg =
      (harness.${
        if backend == "hm"
        then "evalHm"
        else "evalDevenv"
      } (lib.mkMerge [base overlay])).config;
    errors = map (assertion: assertion.message) (lib.filter (assertion: !assertion.assertion) cfg.assertions);
  in {
    inherit errors;
    passed = assert lib.assertMsg (errors == []) (lib.concatStringsSep "\n" errors); true;
  };
in
  lib.genAttrs ["devenv" "hm"] (backend:
    lib.mapAttrs (_name: control: let
      broken = evaluate backend control.broken;
      healthy = evaluate backend control.healthy;
    in {
      inherit broken healthy;
      # Exact diagnostics exclude both silently accepted declarations and
      # unrelated module failures that would make tryEval alone look healthy.
      passed = lib.sort builtins.lessThan broken.errors == lib.sort builtins.lessThan control.expected && healthy.passed;
    })
    cases)
