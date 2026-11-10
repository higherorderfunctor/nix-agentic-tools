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
        name = "Delegate sizing";
        text = "## delegate sizing\n\nEach row is a family: pick the id with the highest version that matches its pattern in the live model list, comparing version numbers segment by segment (6.1 > 6 > 5.6), and use the runtime's own spelling from the introspection step (Claude Agent calls name the generated agent file to pin a full id; plain calls without a file take aliases such as `opus`). The Orchestration column names the default orchestrators and the families reserved for hard work. The Launch column lists, per harness, the techniques that pin the model and supported effort (or intentionally omit effort for families without levels) and take a full id or pattern, in order, with the id spelling each takes; use the first one present in your tool list; a concrete id there is the family's current pick, and \"the highest id matching\" instructs the resolution above.";
      }
      {
        name = "Routing helper";
        text = ''
          ## Routing helper

          {helper}

          Write `--launch-context` JSON with `nonInteractive` (true, false or null), `roles` and `techniques`. Each role maps to a requested `effort` (string or null), optional `avoid` and `exclude` lists of exact configured family names (empty by default), and a `families` map keyed by caller-qualified family name. Exclude wins overlap and removes every route for that family with reason "excluded by caller"; avoid never removes a route by itself; avoid retains eligible alternatives after all non-avoided candidates, with ordinary measured preference and pace ordering within each partition. List order and duplicates add no preference. Each family qualification supplies nonempty `fit`, `useFor`, `avoidFor` and `trial` evidence strings. Each observed technique supplies `runtime`, `technique`, one concrete `model` and its unordered supported `efforts` list; `[]` explicitly attests effort omission support, never unknown availability. Repeat an observed technique for different models only when the family pattern remains unambiguous. Available roles: finder, first-check, investigator, judge, mechanical, planner, second-check, writer. Planner and all four review roles require strong/frontier tiers. Unknown/headless contexts cannot certify external launches. A non-null role effort overrides the candidate family's structured default; otherwise use its `defaultEffort` for every technique; prose effort guidance never supplies a value. Avoided candidates carry fallback metadata (`kind`, `resolvedEffort`, `launchEffort`): resolve the base before advancing to the next supported package scale value (minimal < low < medium < high < xhigh < max), retaining the highest when no higher level exists. Observed no-effort fallbacks launch at null without a bump. A role whose first pick is a fallback prints one notice: `WARNING: <role>: no non-avoided candidate; using fallback <family> at effort <x>. Report this to the user.` Failed Readers and dropped windows print failure warnings ending with "Report this failure to the user." Omit null effort arguments and flags; never bind None/null tokens. A null default requires observed omission support. Consumer family defaults remain overridable. Session pace still compares all otherwise fitting measured candidates, including avoided ones. Preserve floors and try shared fallback before reporting no qualified route. Review callers avoid the writer family; cut judges avoid writer and proposer families; use fresh separate agents with neutral briefs. After a failed launch, rerun with that family added to the affected role's exclude list, retaining the other evidence. JSON goes to stdout; concise routing lines go to stderr. Treat lines as specifications for native calls or orchestrator-bound external launches, never executable shell text. Provider identity is provisional for maker independence; caller fit/trial evidence remains required even above the tier floor.
        '';
      }
      {
        name = "Pools";
        text = "## Pools\n\n{pools}";
      }
      {
        name = "Family tables";
        text = "{families}";
      }
      {
        name = "Technique availability";
        text = "Use a technique only if it appears in your tool list; an external technique's command must be on PATH. The Modes column says where each tool usually appears; an agent cannot reliably tell which mode it is in, but it can see its tools.";
      }
      {
        name = "Technique tables";
        text = "{techniques}";
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
