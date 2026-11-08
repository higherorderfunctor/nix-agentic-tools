# Helper-backed cases use fake Readers with real delegate techniques.
{
  lib,
  pkgs,
  ...
}: let
  fakeReader = name: remaining:
    pkgs.writeScript "routing-eval-reader-${name}" ''
      #!${pkgs.python3}/bin/python3
      from datetime import datetime, timedelta, timezone
      import json
      import os
      from pathlib import Path

      now = datetime.now(timezone.utc)
      receipt = {"reader": "${name}", "remainingPercent": ${toString remaining}, "time": now.isoformat()}
      with Path(os.environ["ROUTING_EVAL_RECEIPTS"]).open("a") as output:
          output.write(json.dumps(receipt) + "\n")
      print(json.dumps({"account": {"auth_index": None, "name": "fixture", "plan": None},
        "balances": [], "bonuses": [], "pool": "not-the-registry-key", "windows": {"5h": {
          "remainingPercent": ${toString remaining},
          "status": "ok",
          "usedPercent": ${toString (100 - remaining)},
          "resetsAt": (now + timedelta(seconds=9000)).isoformat(),
          "windowSeconds": 18000
      }}}))
    '';
in {
  ai.programs.delegate-routing = {
    # Only Reader executables are fake; native delegate techniques stay intact.
    families = {
      openai = lib.genAttrs ["outside" "session" "under-tier"] (name: {
        avoidFor = "sole judging; fixture records tier eligibility only";
        defaultEffort = "medium";
        effort = "medium";
        example.codex = "gpt-6.1-sol";
        match = "gpt-*-sol";
        pools.codex =
          if name == "session"
          then "session"
          else "outside";
        tier =
          if name == "under-tier"
          then "mid"
          else "strong";
        useFor = "bounded Python implementation and planning with separate review";
      });
    };
    pools = lib.mkForce ((lib.genAttrs ["cross-runtime" "outside" "session"] (name: {
        usage = {
          runtime =
            if name == "cross-runtime"
            then "kiro"
            else "codex";
          technique = "eval-${name}";
        };
      }))
      // {
        zai-coding.usage = {
          runtime = "codex";
          technique = "eval-outside";
        };
      });
    runtimes = {
      codex = {
        extraRuntimes = lib.mkForce [];
        manualExternalDelegates = lib.mkForce [];
        models = lib.mkForce [{families = ["outside" "session" "under-tier"];}];
        sessionPool = "session";
        techniques = {
          # Pool references use these names, not the Reader output's .pool.
          eval-outside = {
            command = toString (fakeReader "outside" 80);
            kind = "usage";
          };
          eval-session = {
            command = toString (fakeReader "session" 30);
            kind = "usage";
          };
        };
      };
      kiro.techniques.eval-cross-runtime = {
        command = toString (fakeReader "cross-runtime" 90);
        kind = "usage";
      };
    };
  };
}
