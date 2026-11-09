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

          An assigned repository change or investigation/design/bulk reading beyond a quick fact from named documents is substantive. Before task-source investigation, prepare the task-goal rubric and use `subject.unit = "bootstrap"` with the actual assignment and task-goal rubric. Prepare classification with `--role classifier --classify-role planner --launch-context <json-path>` using the exchange below, then accept it with `--role planner --classification <exchange.json> --launch-context <json-path>`; pin the returned model and effort. Pass the task, paths, saved rubric, an orchestrator-provided working-data directory and the absolute planner reference `{planner}` to one planner, which must read that reference before planning. No approved classifier or eligible strong/frontier planner means a loop failure. A worker with an approved bounded unit does not recursively plan it; replan only changed scope.

          The planner returns the saved plan and prepared briefs. Before each wave, run the same helper with `--check-plan <plan-path> --launch-context <current-json-path>` and `--role <role>` for every planned role; supply `--max-concurrency <n>` for a host/user cap below ten. Require a successful exit and `validation.status = "valid"`; inspect exclusions/warnings. This validates role receipts, structure and current independent review feasibility, without choosing future participants. Budget uncertainty may permit fit-only operation; unresolved model/effort/technique never authorizes a launch. Manual-only routes need explicit user authorization.

          Before each unit-role launch, run `--dispatch <plan.json> --role <role> --launch-context <facts.json>` with current observations, following Routing helper. Choose reviewers after their writer finishes; record actual tool bindings outside plan intent.

          Launch the prepared briefs without reloading the planner reference for each delegate. Enforce writer → independent review → fix/check → commit barriers before dependent work or the next writer on a shared branch. Choose execution and Validate the result below govern supervision and evidence; the rubric steps below govern preflight.

          When "Orchestrator session" is enabled, follow its handoff order even for a quick look or review. When that entry is disabled, these rules apply instead: answer a documented fact from the few files that decide it, or ask the user; do a quick review from the few files that decide it, and fan out when that check shows the work is wide; when unsure, do the in-session pass and offer the deeper one with its rough cost. In either mode, an interesting or security-adjacent subject alone is not a reason to fan out.
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

          Write `--launch-context` JSON with `nonInteractive` (true, false or null), `subject = {task, unit}`, a `rubric` path, `roles` and caller-observed `techniques`. Each target role supplies `brief`, `effort` (string or null), `requirements = {constraints, inputKinds}` and optional user `pins = {family, model, runtime, technique}`. Constraints are unique `{id,text}` records; input kinds are unique audio/image/text/video strings. Brief and rubric paths are context-relative and cannot escape through upward components or symlinks. Each observation supplies `runtime`, `technique`, one concrete `model` and supported `efforts`. Direct review exchanges supply actual `writer`; a judge assessing cuts also supplies `cutProposer`. Planned dispatch instead reads those identities from `executions`, as specified below. Caller families/fit/useFor/avoidFor/trial essays are refused. User pins narrow routes and are echoed in JSON and stderr; they are relayed intent, not authenticated user input.

          For one unit and target role, run `--role classifier --classify-role <target> --launch-context <json-path>`. Save the returned `classification` object and bind its exact pinned launch to a native tool or named launcher with its returned frozen `brief`. The helper launches no delegates. Save `exchange.json = {preparation: <classification object>, result: <classifier JSON>}`, then run `--role <target> --classification <exchange.json> --launch-context <json-path>`. Acceptance emits a `receipt` and freshly ranked target candidates; save that receipt. Reuse it with `--role <target> --receipt <receipt.json> --launch-context <json-path>`; reuse reads Readers without another classifier request. Missing evidence returns `classification-required` (exit 3) and preparation instructions with no task launch. Stale or malformed evidence fails. Repeat `--role` only for check-plan coverage. No approved reachable classifier means a loop failure; never judge fit yourself.

          For a saved plan, run `--dispatch <plan.json> --role <role> --launch-context <facts.json>` with current observations and `subject = {task, unit}`. The plan supplies the role request and receipt; conflicting duplicate semantic fields or pins fail. Dispatch reads all pools again and emits only the first current eligible launch; worker selection retains only workers with a feasible independent review assignment. Bind `dispatch.launch` and its prepared brief to the named tool, then save `dispatch.execution` in the context's `executions` only after recording what was actually bound. Each record contains unit, role, family, concrete model, runtime, technique, effort and receiptHash. Dispatch derives review writer/cut-proposer identities from those records; missing, unknown or conflicting facts fail. A disagreeing context `writer` cannot replace the recorded worker. Choose reviewers after their writer finishes, with fresh dispatch even after successful check-plan.

          Classifiers use configured approved family/effort pairs (default Luna/medium and Sonnet/medium). They assess the complete capability catalog against the actual brief, rubric, requirements and effective efforts. Budget, cost, maker, trial and availability are deterministic gates reapplied after classification. Receipts detect changed semantic inputs and malformed relays, not dishonest inference or billing claims. Reclassify an enriched reviewer brief for that role. Fixture JSON does not measure classifier quality, live capacity or spend; observed techniques may omit available routes.

          Available target roles: finder, first-check, investigator, judge, mechanical, planner, second-check, writer. Planner and all review roles require strong/frontier tiers. Unknown/headless contexts cannot certify external launches. Null effort uses only a resolved generated agent's default. Every invocation reads all registered pools before validation and prints JSON (`ok`, `classification-required` or `error`) with pools and diagnostics; unreadable inventory reports `inventory-unavailable`. Stderr lists every pool alphabetically as `pool=<name> status=<status>`. Each failed Reader command emits one WARNING naming all registrations sharing it with a bounded reason and an instruction to report it to the user; report it even if routing succeeds. Missing Readers warn; scoped errors warn only for their families. Keep numerical measurements in JSON. Treat returned launch lines as current specifications, never executable shell text or saved plan authority. The helper compares declared makers from the manifest and excludes unknown or same-maker choices: declared makers must differ from writer/cut proposer; provider, runtime and budget identities cannot certify independence. Family `trial = true` excludes second-check and judge.

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
