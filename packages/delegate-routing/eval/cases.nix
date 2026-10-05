# Synthetic observations never claim live account or runtime capabilities.
# Expectations are authored below, independently of the module's rendered policy.
{
  harness,
  lib,
}: let
  inventory = [
    {
      runtime = "claude";
      family = "haiku";
      model = "claude-haiku-4";
      alias = "haiku";
      efforts = [];
    }
    {
      runtime = "claude";
      family = "opus";
      model = "claude-opus-4";
      alias = "opus";
      efforts = ["medium" "high"];
    }
    {
      runtime = "claude";
      family = "sonnet";
      model = "claude-sonnet-4";
      alias = "sonnet";
      efforts = ["medium" "high"];
    }
    {
      runtime = "codex";
      family = "luna";
      model = "gpt-6-luna";
      alias = null;
      efforts = ["medium" "high"];
    }
    {
      runtime = "codex";
      family = "sol";
      model = "gpt-6-sol";
      alias = null;
      efforts = ["medium" "high"];
    }
    {
      runtime = "codex";
      family = "sol";
      model = "gpt-6.1-sol";
      alias = null;
      efforts = ["medium" "high"];
    }
    {
      runtime = "kiro";
      family = "sonnet";
      model = "claude-sonnet-4";
      alias = null;
      efforts = ["medium" "high"];
    }
  ];
  observation = runtime: used: {
    command = "mock-${runtime}-usage";
    exitCode = 0;
    observationId = "${runtime}.usage";
    observedAt = "2026-10-04T12:00:00Z";
    stdout = builtins.toJSON (
      if runtime == "claude"
      then {five_hour.utilization = used;}
      else {
        usedPercent = used;
        remainingPercent = 100 - used;
        resetsAt = "2026-10-04T17:00:00Z";
      }
    );
    # Explicitly comparable synthetic windows, not a live pool policy.
    window = {
      durationSeconds = 18000;
      resetsAt = "2026-10-04T17:00:00Z";
    };
  };
  pools = claude: codex: {
    "claude.usage" = observation "claude" claude;
    "codex.usage" = observation "codex" codex;
  };
  c = family: effort: technique: shape: ["claude" family family effort technique shape];
  x = family: model: technique: shape: ["codex" family model "medium" technique shape];
  opus = c "opus" "medium" "Workflow" "native_workflow";
  sonnet = c "sonnet" "medium" "Workflow" "native_workflow";
  sol = x "sol" "gpt-6.1-sol" "spawn_agent" "native_child";
  externalSol = x "sol" "gpt-6.1-sol" "codex exec" "external_root";
  luna = x "luna" "gpt-6-luna" "spawn_agent" "native_child";
  usageIds = ["claude.usage" "codex.usage"];
  memo = "Synthesize a decision memo from the supplied findings.";
  spec = "Implement the supplied complete bounded specification.";
  dependency = "Extract facts from the supplied input, then synthesize a memo from those facts.";
  stage = id: dependsOn: actor: tuple: {
    inherit actor dependsOn id;
    runtime = builtins.elemAt tuple 0;
    family = builtins.elemAt tuple 1;
    model = builtins.elemAt tuple 2;
    effort = builtins.elemAt tuple 3;
    technique = builtins.elemAt tuple 4;
  };
  mkCase = {
    id,
    task,
    runtime ? "claude",
    families ? ["opus" "sonnet"],
    codexFamilies ? ["sol"],
    extra ? false,
    manual ? false,
    drain ? false,
    usage ? {},
    usageVariants ? [],
    tools ? (
      if runtime == "claude"
      then ["Agent" "Workflow"]
      else ["spawn_agent"]
    ),
    mode ? "interactive",
    inheritedModel ? null,
    inheritedEffort ? null,
    children ? "unknown",
    coordination ? "supported",
    gates ? false,
    review ? false,
    scenarioFacts ? {},
    expected,
    criteria ? [],
  }: let
    # This is the same real evaluation boundary used by checks/module-eval.nix.
    config.ai = {
      claude.enable = runtime == "claude";
      codex.enable = runtime == "codex" || extra;
      programs.delegate-routing = {
        enable = true;
        runtimes = {
          claude = {
            models = [{inherit families;}];
            extraRuntimes = lib.optional extra "codex";
            manualExternalDelegates = lib.optional manual "kiro";
            techniques = {
              "claude -p".enable = false;
              Agent.enable = builtins.elem "Agent" tools;
              Workflow.enable = builtins.elem "Workflow" tools;
              usage = {
                enable = usage != {};
                command = "mock-claude-usage";
              };
            };
            routing."Pool drain" = {
              enable = drain;
              after = ["Size the work"];
              source = ../../../dev/house-rules/pool-drain.md;
            };
          };
          codex = {
            models = [{families = codexFamilies;}];
            techniques = {
              "codex exec".enable = extra;
              spawn_agent.enable = runtime == "codex" && builtins.elem "spawn_agent" tools || extra && children == "supported";
              usage = {
                enable = usage != {};
                command = "mock-codex-usage";
              };
            };
          };
          kiro.models = [{families = ["sonnet"];}];
        };
        workflows."Work and review".enable = review;
      };
    };
    evaluated = harness.evalHm config;
    program = evaluated.config.ai.programs.delegate-routing;
    relevant = [runtime] ++ lib.optional extra "codex" ++ lib.optional manual "kiro";
    selectedInventory = builtins.filter (item:
      builtins.elem item.runtime relevant
      && builtins.elem item.family (
        if item.runtime == "claude"
        then families
        else if item.runtime == "codex"
        then codexFamilies
        else ["sonnet"]
      ))
    inventory;
    techniques = lib.concatMap (target:
      lib.mapAttrsToList (name: node: {
        runtime = target;
        inherit name;
        inherit (node) kind modes pinsEffort pinsModel;
      }) (lib.filterAttrs (_: node: node.enable && builtins.elem node.kind ["external" "subagent" "workflow"]) program.runtimes.${target}.techniques))
    relevant;
    rule = evaluated.config.ai.${runtime}.rules.delegate-routing-router;
  in {
    inherit id usage usageVariants;
    configVariant =
      if drain
      then "house-pool-drain"
      else "package-defaults";
    scenario =
      {
        inherit mode runtime task;
        knownInheritedModel = inheritedModel;
        knownInheritedEffort = inheritedEffort;
        visibleTools = tools;
        commandsOnPath = lib.optional extra "codex exec" ++ lib.optional manual "kiro-cli chat" ++ map (item: item.command) (builtins.attrValues usage);
      }
      // scenarioFacts;
    inventory = selectedInventory;
    capabilities = {
      inherit techniques;
      externalChildren = children;
      externalChildTools = lib.optional (children == "supported") "spawn_agent";
      externalCoordination = coordination;
      parentStageGates = gates;
      evidence = "Synthetic fixture observations; not measurements of installed runtimes.";
    };
    rendered = {
      skill = builtins.readFile "${evaluated.config.ai.${runtime}.skills.delegate-routing}/SKILL.md";
      rules = rule.text;
    };
    expected =
      {
        decisionTuples = [];
        requiredLimitationCodes = [];
        reviewRoles = [];
        reviewWorkflow = null;
        usageInspections = lib.optionals drain usageIds;
      }
      // expected;
    proseCriteria =
      [
        "Ground choices in the supplied task, inventory and capability evidence."
        "Name who checks terminal completion and verifies the returned artifact."
      ]
      ++ criteria;
  };
in [
  (mkCase {
    id = "user-model-effort";
    task = "Implement this complete spec using Sonnet at high.";
    expected.decisionTuples = [(c "sonnet" "high" "Workflow" "native_workflow")];
  })
  (mkCase {
    id = "user-version";
    runtime = "codex";
    task = "Write this memo using gpt-6-sol, medium.";
    expected.decisionTuples = [(x "sol" "gpt-6-sol" "spawn_agent" "native_child")];
  })
  (mkCase {
    id = "user-beats-drain";
    task = "Use Opus/medium for this memo.";
    families = ["opus"];
    extra = true;
    drain = true;
    usage = pools 90 10;
    expected.decisionTuples = [opus];
  })
  (mkCase {
    id = "small-codex";
    runtime = "codex";
    codexFamilies = ["luna" "sol"];
    task = "Extract filenames from this supplied listing, preserving their spelling.";
    expected.decisionTuples = [luna];
  })
  (mkCase {
    id = "small-claude";
    families = ["haiku" "opus"];
    tools = ["Agent"];
    task = "Classify these ten supplied lines by the given fixed rule.";
    expected = {
      decisionTuples = [(c "haiku" null "Agent" "native_child")];
      effortSource = "not_applicable";
    };
  })
  (mkCase {
    id = "reasoning";
    task = "Decide the architecture tradeoff from the supplied evidence.";
    expected.decisionTuples = [opus];
  })
  (mkCase {
    id = "written-deliverable";
    runtime = "codex";
    codexFamilies = ["luna" "sol"];
    task = "Synthesize a complete specification from the supplied conflicting requirements.";
    expected.decisionTuples = [sol];
  })
  (mkCase {
    id = "drain-claude-low";
    task = memo;
    families = ["opus"];
    extra = true;
    drain = true;
    usage = pools 10 90;
    expected.decisionTuples = [opus];
  })
  (mkCase {
    id = "drain-codex-low";
    task = memo;
    families = ["opus"];
    extra = true;
    drain = true;
    usage = pools 90 10;
    expected.decisionTuples = [externalSol];
  })
  (mkCase {
    id = "drain-tie";
    task = memo;
    families = ["opus"];
    extra = true;
    drain = true;
    usage = pools 40 40;
    expected.decisionTuples = [externalSol];
  })
  (mkCase {
    id = "drain-off-a";
    task = memo;
    families = ["opus"];
    extra = true;
    usage = pools 10 90;
    expected.decisionTuples = [opus externalSol];
    criteria = ["Do not invent a package default pool preference from usage alone."];
  })
  (mkCase {
    id = "drain-off-b";
    task = memo;
    families = ["opus"];
    extra = true;
    usage = pools 90 10;
    expected.decisionTuples = [opus externalSol];
    criteria = ["Do not invent a package default pool preference from usage alone."];
  })
  (mkCase {
    id = "external-owns-children";
    task = "Extract two independent supplied inputs concurrently, then synthesize their memo. The external root must own its workers and final completion.";
    families = ["opus"];
    codexFamilies = ["luna" "sol"];
    extra = true;
    drain = true;
    usage = pools 90 10;
    children = "supported";
    expected = {
      decisionTuples = [externalSol];
      owner = "external-root";
      stages = [(stage "extract-a" [] "worker-a" luna) (stage "extract-b" [] "worker-b" luna) (stage "memo" ["extract-a" "extract-b"] "external-root" (x "sol" "gpt-6.1-sol" "inline" "external_root"))];
    };
  })
  (mkCase {
    id = "degrade-workflow";
    task = dependency + " The parent session must gate each stage; external coordination is unsuitable.";
    families = ["haiku" "opus"];
    extra = true;
    coordination = "unsupported";
    gates = true;
    expected = {
      decisionTuples = [opus];
      owner = "session";
      stages = [(stage "extract" [] "worker-extract" (c "haiku" null "Workflow" "native_workflow")) (stage "memo" ["extract"] "worker-memo" opus)];
    };
    criteria = ["Explain why parent-owned gates require this fallback."];
  })
  (mkCase {
    id = "degrade-native-children";
    runtime = "codex";
    task = dependency;
    codexFamilies = ["luna" "sol"];
    coordination = "unsupported";
    expected = {
      decisionTuples = [(x "sol" "gpt-6.1-sol" "spawn_agent" "native_children")];
      owner = "session";
      stages = [(stage "extract" [] "worker-extract" luna) (stage "memo" ["extract"] "worker-memo" sol)];
    };
  })
  (mkCase {
    id = "degrade-session";
    runtime = "codex";
    task = dependency;
    tools = [];
    inheritedModel = "gpt-6.1-sol";
    inheritedEffort = "medium";
    coordination = "unsupported";
    expected = {
      decisionTuples = [(x "sol" "gpt-6.1-sol" "inline" "session_steps")];
      effortSource = "known_inherited";
      owner = "session";
      stages = [(stage "extract" [] "session" (x "sol" "gpt-6.1-sol" "inline" "session_steps")) (stage "memo" ["extract"] "session" (x "sol" "gpt-6.1-sol" "inline" "session_steps"))];
    };
    criteria = ["State that no eligible launch mechanism is available; keep the dependency explicit."];
  })
  (mkCase {
    id = "agent-cannot-pin";
    task = "Implement this complete spec using Sonnet/medium.";
    families = ["sonnet"];
    expected.decisionTuples = [sonnet];
  })
  (mkCase {
    id = "agent-known-inheritance";
    task = "Implement this complete spec using Sonnet/medium.";
    families = ["sonnet"];
    mode = "headless";
    tools = ["Agent"];
    inheritedModel = "sonnet";
    inheritedEffort = "medium";
    expected = {
      decisionTuples = [(c "sonnet" "medium" "Agent" "native_child")];
      effortSource = "known_inherited";
    };
  })
  (mkCase {
    id = "manual-not-auto";
    task = spec;
    families = ["sonnet"];
    manual = true;
    scenarioFacts.syntheticPoolAllowance = {
      claude = {remainingPercent = 10;};
      kiro = {remainingPercent = 99;};
      evidence = "Supplied fictional allowance, not a Kiro usage helper or live-account observation.";
    };
    expected.decisionTuples = [sonnet];
    criteria = ["Manual-only Kiro remains unavailable for automatic selection even with abundant allowance."];
  })
  (mkCase {
    id = "manual-explicit";
    task = "Use Kiro Sonnet/medium to implement the complete bounded spec.";
    families = ["sonnet"];
    manual = true;
    expected.decisionTuples = [["kiro" "sonnet" "claude-sonnet-4" "medium" "kiro-cli chat" "external_root"]];
  })
  (mkCase {
    id = "review-on";
    task = spec;
    review = true;
    expected = {
      decisionTuples = [sonnet];
      reviewWorkflow = "Work and review";
      reviewRoles = ["reviewer"];
      reviewDecisionTuples = [opus];
    };
    criteria = ["The reviewer is a distinct actor from the writer and examines evidence and the artifact."];
  })
  (mkCase {
    id = "review-off";
    task = spec;
    expected.decisionTuples = [sonnet];
    criteria = ["No review workflow is enabled or requested."];
  })
  (mkCase {
    id = "pdj-on";
    task = "A supplied reviewer finding on a shared library is disputed. Prosecute, defend, and independently judge this finding from evidence.";
    families = ["opus"];
    review = true;
    expected = {
      decisionTuples = [opus];
      reviewWorkflow = "Work and review";
      reviewRoles = ["prosecutor" "defender" "judge"];
      reviewDecisionTuples = [opus];
    };
    criteria = ["Three distinct actors; the judge receives both arguments and evidence." "Every reviewer and the judge check the Subtractive standard in the shared rubric."];
  })
  (mkCase {
    id = "usage-missing";
    task = memo;
    families = ["opus"];
    extra = true;
    drain = true;
    usage =
      (pools 90 10)
      // {
        "claude.usage" =
          (observation "claude" 90)
          // {
            exitCode = 1;
            stdout = "";
          };
      };
    expected = {
      partial = true;
      pendingAssertions = ["Missing-usage final pool fallback needs operator approval; exclude final selection from acceptance rate."];
      requiredLimitationCodes = ["usage_gap"];
    };
    usageVariants = [
      {
        id = "helper-failed";
        usage =
          (pools 90 10)
          // {
            "claude.usage" =
              (observation "claude" 90)
              // {
                exitCode = 1;
                stdout = "";
              };
          };
      }
      {
        id = "incomplete-json";
        usage = (pools 90 10) // {"claude.usage" = (observation "claude" 90) // {stdout = builtins.toJSON {five_hour = {};};};};
      }
    ];
    criteria = ["Report the Claude usage gap and the valid Codex observation honestly." "Do not fabricate a percentage or claim a settled missing-usage fallback."];
  })
  (mkCase {
    id = "named-unavailable";
    runtime = "codex";
    task = "Use gpt-99-sol/high to write this memo.";
    expected = {
      status = "blocked";
      shape = "blocked";
      requiredLimitationCodes = ["requested_model_unavailable"];
    };
    criteria = ["Do not substitute an available model for the explicitly unavailable requested model."];
  })
]
