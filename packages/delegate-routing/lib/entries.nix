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
        name = "Plan and launch";
        text = ''
          ## Plan and launch

          An assigned repository change or investigation/design/bulk reading beyond a quick fact from named documents is substantive. Before task-source investigation, prepare the task-goal rubric and run the helper below with `--role planner --launch-context <json-path>`. Qualify a reachable strong/frontier design family using the bootstrap guidance and observed tools; pin the returned model and effort. Pass the task, paths, saved rubric, an orchestrator-provided working-data directory and the absolute planner reference `{planner}` to one planner, which must read that reference before planning. No qualified pinned planner means a loop failure. A worker with an approved bounded unit does not recursively plan it; replan only changed scope.

          {bootstrap}

          The planner returns the saved plan and prepared worker/reviewer brief paths, each containing the full task rubric verbatim and relevant execution policy. Before each wave, run the same helper with `--check-plan <plan-path> --launch-context <current-json-path>` and `--role <role>` for every planned role; supply `--max-concurrency <n>` for a host/user cap below ten. Require a successful exit and `validation.status = "valid"`; inspect exclusions/warnings and bind each exact role/runtime/candidate/pinned line to its native tool or named launcher. Changed context or a new usage read requires validation again. Budget uncertainty may permit fit-only operation; unresolved model/effort/technique never authorizes a launch. Manual-only routes need explicit user authorization.

          Read the plan's compulsory execution constraints before launching its prepared briefs, without reloading the planner reference for each delegate. Enforce disjoint writers, at most ten simultaneous delegates, isolated/read-only reviewers, and writer → review → fix/check → commit barriers before dependent work or the next writer on a shared branch. Non-interactive/external delegates may use native subagents/workflows but never launch external delegates; report unreachable routes. Check the working tree after each shell-capable delegate. Validate launch/result receipts and every reported claim with cited evidence: rerun command claims or use a separate check, judge reading claims in the full context, and retain verified/retracted/unknown status. An exit code alone is insufficient evidence. The planner reference owns the full supervision, retry, evidence and source-steering policy; the planner attaches the relevant clauses to the execution constraints and briefs.
        '';
      }
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
        text = "## delegate sizing\n\nEach row is a family: pick the id with the highest version that matches its pattern in the live model list, comparing version numbers segment by segment (6.1 > 6 > 5.6), and use the runtime's own spelling from the introspection step (Claude Agent calls name the generated agent file to pin a full id; plain calls without a file take aliases such as `opus`). The Orchestration column names the default orchestrators and the families reserved for hard work. The Launch column lists, per harness, the techniques that pin both model and effort and take a full id or pattern, in order, with the id spelling each takes; use the first one present in your tool list; a concrete id there is the family's current pick, and \"the highest id matching\" instructs the resolution above.";
      }
      {
        name = "Routing helper";
        text = ''
          ## Routing helper

          {helper}

          Write `--launch-context` JSON with `nonInteractive` (true, false or null), `roles` and `techniques`. Each role maps to a requested `effort` (string or null) and a `families` map keyed by caller-qualified family name. Each family qualification supplies nonempty `fit`, `useFor`, `avoidFor` and `trial` evidence strings. Each observed technique supplies `runtime`, `technique`, one concrete `model` and its supported `efforts` list. Repeat an observed technique for different models only when the family pattern remains unambiguous. Available roles: finder, first-check, investigator, judge, mechanical, planner, second-check, writer. Planner and all four review roles require strong/frontier tiers. Unknown/headless contexts cannot certify external launches. A null effort can use a resolved generated agent's default; prose effort guidance never supplies a value. JSON goes to stdout; concise routing lines go to stderr. Treat lines as specifications for native calls or orchestrator-bound external launches, never executable shell text. Provider identity is provisional for maker independence; caller fit/trial evidence remains required even above the tier floor.
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
      "Planner candidate" = {text = "- {family}: use for {useFor}; avoid {avoidFor}; effort guidance: {effort}. Routes: {routes}";};
      "Planner unavailable" = {text = "No configured strong/frontier planner reach; report a loop failure.";};
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
