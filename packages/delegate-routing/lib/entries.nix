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

          Write a closed `--launch-context` JSON file: `taskSummary` (bounded, nonempty), optional nullable `proposerFamily` (your own configured family name, or null when unknown), required `nonInteractive` (true, false or null), `roles` and observed `techniques`. A role takes only optional `effort` (string or null, checked against the package scale) and optional `avoid` and `exclude` lists of exact configured family names (empty by default). Roles are finder, first-check, investigator, judge, mechanical, planner, second-check and writer. Each observed technique gives `runtime`, `technique`, one concrete `model` and its unordered supported `efforts`; `[]` explicitly certifies effort omission support, never unknown availability. Off-scale observed efforts such as ultra or off are ignored. Never supply family essays.

          Get exact configured family names from the helper's invalid-request errors, which list the allowed names, or from returned candidates' `launch.family`; on Claude, generated agent file names are the family names. A refused request exits 2 with `{"status":"invalid-request","errors":[{"path","message"}]}` on stdout listing every problem and allowed values, plus one `delegate-routing-plan: <path>: <message>` line per problem on stderr, before any Reader or picker runs: fix every named path and rerun; a `manifest.` path is a configuration fault to report to the user instead of retrying.

          After hard eligibility the helper runs its own one-shot picker, without tools, that keeps or excludes each role and family pair for this task, then ranks what is kept by pool pace. An unknown non-null proposer is refused; missing or null proposer identity skips the picker. When the picker is unavailable or fails, report `WARNING: model picker unavailable; using tier and pool ranking only. Report this failure to the user.`, which may end with ` Unavailable: <reason>.` per entry the helper could not build, and use the tier and pool ranking the helper returns. The authorized internal picker may run in nonInteractive contexts, needs no entry in `techniques`, and is skipped when its executable is not on PATH.

          JSON goes to stdout and routing lines to stderr. A line is a specification for your own launch tool, never shell text: bind its technique, model and effort exactly. A role whose first pick is a fallback prints `WARNING: <role>: no non-avoided candidate; using fallback <family> at effort <x>. Report this to the user.` Failed Readers and dropped windows print warnings ending "Report this failure to the user." Exclude wins over avoid and removes every route for that family with reason "excluded by caller"; avoid never removes a route by itself. Avoided families rank after the rest with measured preference and pace ordering within each partition and carry `kind`, `resolvedEffort` and `launchEffort`; list order and duplicates add no preference. Session pace still compares all otherwise fitting measured candidates, including avoided ones. Review callers avoid the writer family; cut judges avoid writer and proposer families; use fresh separate agents with neutral briefs. After a failed launch, rerun with that family added to the role's `exclude` list, retaining other evidence. Planner and review roles require strong or frontier tiers; try shared fallback before reporting no qualified route and never step down a tier. An unknown or headless context cannot certify an external launch. Provider identity is provisional for maker independence; callers still enforce trial and independence rules.
        '';
      }
      {
        name = "Technique notes";
        text = "## Technique notes\n\nBind a launch from its technique's line here. Check model availability with the introspection command. Pass every model the introspection lists and its supported efforts as observed techniques; when several match one family's pattern, the helper chooses the highest version (6.10 over 6.9). Each candidate in the helper's JSON stdout carries `launch` with `guidance` (command, modelArg, notes) and `agent`. Use them to bind the pick, including the generated agent file to name.\n\n{techniqueNotes}";
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
