{lib}: let
  # Every record follows all earlier ones, so disabling any one keeps the rest
  # in order.
  chain = records:
    builtins.listToAttrs (lib.imap0 (index: record: {
        inherit (record) name;
        value =
          {after = map (earlier: earlier.name) (lib.take index records);}
          // lib.getAttrs (builtins.filter (key: record ? ${key}) ["source" "text"]) record;
      })
      records);
  columns = names:
    chain (map (name: {
        inherit name;
        text = name;
      })
      names);
in {
  routing = {
    "Choose execution" = {
      after = ["Size the work"];
      source = ../fragments/choose-execution.md;
    };
    "Follow the user's request".source = ../fragments/follow-the-users-request.md;
    "Load delegate-routing" = {
      always = true;
      source = ../fragments/load-delegate-routing.md;
    };
    "Orchestrator session" = {
      always = true;
      enable = true;
      source = ../fragments/orchestrator-session.md;
    };
    "Pool drain" = {
      after = ["Size the work"];
      always = true;
      source = ../fragments/pool-drain.md;
    };
    "Size the work" = {
      after = ["Follow the user's request"];
      source = ../fragments/size-the-work.md;
    };
    "Tune these rules" = {
      after = ["Choose execution"];
      source = ../fragments/tune-these-rules.md;
    };
    "Validate the result" = {
      after = ["Choose execution"];
      always = true;
      source = ../fragments/validate-the-result.md;
    };
  };
  skill = {
    columns = {
      families = columns ["Family" "Orchestration" "Use for" "Avoid for" "Effort (delegate)" "Pool" "Launch"];
      pools = columns ["Name" "Reader" "Measure" "Description"];
      techniques = columns ["Technique" "Kind" "Pins model" "Pins effort" "Modes" "Runs own subagents" "Notes" "Command"];
    };
    entries = chain [
      {
        name = "Routing";
        text = "## Routing\n\n{routing}";
      }
      {
        name = "Common workflows";
        text = "## Common workflows\n\n{workflows}";
      }
      {
        name = "Routing helper";
        text = ''
          ## Routing helper

          {helper}

          Write a closed `--launch-context` JSON file: `taskSummary` (bounded, nonempty), optional nullable `proposerFamily` (your own configured model-line name, or null when unknown), required `nonInteractive` (true, false or null), `roles` and optional `caller`. A role takes optional `producers` records (`family` and actual launch `effort`), an unordered `exclude` list of configured model-line or maker names, and `effort` as a signed step offset such as `+1` or `-1`, or null. Checking roles derive their offset from producers and cannot also request one. Roles are finder, first-check, investigator, judge, mechanical, planner, second-check and writer. Optional caller identity attests current `family`, concrete `model` and actual `effort` for a self last resort. Never supply family essays or a techniques list: routes come from the generated manifest.

          Get exact configured family and maker names from the helper's invalid-request errors, which list allowed names, or returned launch records and manifest metadata; on Claude, generated agent file names are the family names. A refused request exits 2 with `{"status":"invalid-request","errors":[{"path","message"}]}` on stdout listing every problem and allowed values, plus one `delegate-routing-plan: <path>: <message>` line per problem on stderr, before any Reader or picker runs: fix every named path and rerun; a `manifest.` path is a configuration fault to report to the user instead of retrying.

          After hard eligibility the helper runs its own tool-free one-shot picker to keep or exclude each role/family pair, then uses the producer and pool ladder in Pool drain. Picker entries run in pool order; the proposer model line is allowed. An unknown non-null proposer is refused; missing or null identity skips the picker. When it is unavailable or fails, report `WARNING: model picker unavailable; using tier and pool ranking only. Report this failure to the user.` with its ` Unavailable: <reason>.` suffixes for unknown identity, missing entries, eligibility refusals, local preparation or attempt failures. Use the returned tier/pool ranking. The authorized internal picker may run in nonInteractive contexts; it launches no workers.

          JSON goes to stdout and routing lines to stderr. Bind a line's technique, model and effort exactly in your launch tool; it is a specification, never shell text. Failed Readers and dropped windows print warnings ending "Report this failure to the user." Exclude removes every matching model-line or maker route with reason "excluded by caller". The helper returns the top three, spreading across pools where possible, plus a retained producer-line or caller last resort without duplication. Review callers name the writer as a producer; cut judges name writer and cut proposer with actual launch efforts. Use fresh separate agents with neutral briefs. After a failed launch, rerun with that family in the role's `exclude` list. Planner and review roles require strong or frontier; checkers never run below producer tier. Report no qualified route only when every route is hard-filtered and the caller cannot run itself. Unknown or headless context forbids external worker routes, including the last resort; callers still enforce trial and independence rules.
        '';
      }
      {
        name = "Technique notes";
        text = "## Technique notes\n\nBind a launch from its technique's line here. Routes come from enabled manifest reaches. The helper resolves a Nix pin first, else the highest matching visible local catalog version (6.10 over 6.9). Codex reads its local models cache; a listed pin uses catalog efforts, otherwise Nix-declared efforts remain and `launch.effortSource` names the fallback. Unresolved routes carry a JSON reason. Each delegate candidate in the helper's JSON stdout carries `launch` with `guidance` (command, modelArg, notes) and `agent`; a last resort with `action` `continue-self` carries only action, runtime, family, model and effort. Use them to bind the pick, including the generated agent file to name.\n\n{techniqueNotes}";
      }
      {
        name = "Manual-only external delegates";
        text = "## manual-only external delegates\n\n{manual}";
      }
    ];
    phrases = {
      "External reach" = {text = "via {harness}: {launch}{pool}";};
      "Family table heading" = {text = "### {tier}";};
      "Launch fallback" = {text = ", else ";};
      "Launch route" = {text = "`{technique}` with {modelArg} {model}";};
      "Manual delegate heading" = {text = "### {harness}";};
      "Manual delegate note" = {text = "Not a candidate for auto-selection; use only when the user names it.";};
      "Manual pool hint" = {text = "; {pool}";};
      "Model pattern" = {text = "the highest id matching `{match}`";};
      "Native reach" = {text = "{harness}: {launch}{pool}";};
      "OpenCode Go note" = {text = "The opencode-go families come from per-model research: their tiers and effort guidance are provisional, not measured on this workload.";};
      "Pool binding" = {text = " (pool {pool})";};
      "Pool measured" = {text = "measured";};
      "Pool reader missing" = {text = "none";};
      "Pool unmeasured" = {text = "unknown";};
      "Pool window" = {text = "configured: {limit} {unit} per month, resets day {resetDay}; current use unknown";};
      "Technique notes heading" = {text = "### {harness} technique notes";};
      "Technique table heading" = {text = "### {harness} techniques";};
    };
  };
  workflows."Work and review" = {
    source = ../fragments/work-and-review.md;
    steps = chain [
      {
        name = "Rubric";
        source = ../fragments/review-rubric.md;
      }
      {
        name = "Subtractive";
        source = ../fragments/review-subtractive.md;
      }
      {
        name = "Plan";
        source = ../fragments/plan-work.md;
      }
      {
        name = "Work";
        source = ../fragments/review-work.md;
      }
      {
        name = "Describe";
        source = ../fragments/review-describe.md;
      }
      {
        name = "Review";
        source = ../fragments/review-checks.md;
      }
      {
        name = "Loop";
        source = ../fragments/review-loop.md;
      }
    ];
  };
}
