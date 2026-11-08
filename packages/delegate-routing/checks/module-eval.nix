# cspell:ignore Prio sublist
# Exercise the generated files as delivered through both consumer backends.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) evalDevenv evalHm mkTest setEnable;
  runtimes = ["claude" "codex" "kimchi" "kiro"];
  scenario.ai = {
    claude.enable = true;
    codex.enable = true;
    kimchi = {
      enable = true;
      # Home Manager requires an account region.
      native.settings.region = "us";
    };
    kiro.cli.enable = true;
    programs.delegate-routing = {
      enable = true;
      # The package ships no Kimchi families, so the scenario declares one.
      families.served.flash = {
        match = "test-flash-*";
        tier = "small";
        useFor = "TEST KIMCHI FAMILY";
      };
      runtimes = {
        claude = {
          extraRuntimes = ["codex"];
          manualExternalDelegates = ["kimchi" "kiro"];
        };
        kimchi.models = [{vendors = ["served"];}];
        kiro.models = [
          {
            vendors = ["anthropic"];
            tiers = ["strong" "small"];
          }
        ];
      };
    };
  };
  hasLoadInstruction = text: lib.hasInfix "load the delegate-routing skill" (lib.toLower (lib.replaceStrings ["\n" "`"] [" " ""] text));
  readPlanner = result: runtime: builtins.readFile "${result.config.ai.${runtime}.skills.delegate-routing}/PLANNER.md";
  readSkill = result: runtime: builtins.readFile "${result.config.ai.${runtime}.skills.delegate-routing}/SKILL.md";
  # Manifest bytes may change while the compared prose stays identical.
  withoutHelperPath = text: lib.concatStringsSep "<helper>" (builtins.filter builtins.isString (builtins.split "/nix/store/[a-z0-9]+-delegate-routing-plan/bin/delegate-routing-plan" text));
  optionTree = result: path: lib.getAttrFromPath path result.options;
  checkBackend = {
    name,
    evaluate,
  }: let
    result = evaluate scenario;
    claude = readPlanner result "claude";
    codex = readPlanner result "codex";
    kimchi = readPlanner result "kimchi";
    kiro = readPlanner result "kiro";
    stub = result.config.ai.claude.rules.delegate-routing-router.text;
    change = config: evaluate (lib.recursiveUpdate scenario config);
    skill = config: readPlanner (change config) "claude";
    # Match the observed pre-split baselines: default native Claude/Codex and
    # all Anthropic families for otherwise unselected Kimchi/Kiro.
    sizeResult = change {
      ai.programs.delegate-routing.runtimes = {
        claude = {
          extraRuntimes = [];
          manualExternalDelegates = [];
        };
        kimchi.models = [{vendors = ["anthropic"];}];
        kiro.models = [{vendors = ["anthropic"];}];
      };
    };
    passes = evaluation: lib.all (item: item.assertion) evaluation.config.assertions;
    failsWith = evaluation: option: lib.any (item: !item.assertion && lib.hasInfix option item.message) evaluation.config.assertions;
    evaluationFails = evaluation: !(builtins.tryEval (builtins.deepSeq evaluation.config.ai.programs.delegate-routing.runtimes.claude true)).success;
    # The rendered skill itself refuses bad input by throwing, so a failing
    # scenario is one whose skill cannot be rendered.
    skillFails = config: !(builtins.tryEval (builtins.deepSeq (skill config) true)).success;
    # Rendering indents continuation lines and the formatter re-wraps them, so
    # prose is matched with every whitespace run collapsed to one space.
    hasProse = needle: text: lib.hasInfix needle (lib.concatStringsSep " " (builtins.filter (part: builtins.isString part && part != "") (builtins.split "[[:space:]]+" text)));
    native = change {ai.programs.delegate-routing.runtimes.claude.extraRuntimes = [];};
    nativeClaude = readPlanner native "claude";
    disabled = evaluate {
      ai.programs.delegate-routing.enable = true;
      ai.programs.delegate-routing.runtimes.codex.enable = false;
    };
    reminderCases = lib.genAttrs runtimes (runtime:
      if name == "hm" && runtime == "kimchi"
      then 0
      else 1);
    hookRuntimes = lib.attrNames (lib.filterAttrs (_: count: count == 1) reminderCases);
    reminderCommands = evaluation: runtime:
      if runtime == "kiro"
      then lib.optional (evaluation.config.ai.kiro.hooks ? delegate-routing-reminder) evaluation.config.ai.kiro.hooks.delegate-routing-reminder.action.command
      else
        lib.filter (lib.hasInfix "delegate-routing-reminder")
        (lib.concatMap (block: map (handler: handler.command) block.hooks) (evaluation.config.ai.${runtime}.hooks.UserPromptSubmit or []));
    hasReminder = evaluation: runtime: reminderCommands evaluation runtime != [];
    reminderOff = change {ai.programs.delegate-routing.reminder.enable = false;};
    reminderOverride = runtime:
      change {
        ai.programs.delegate-routing = {
          reminder.enable = false;
          runtimes.${runtime}.reminder.enable = true;
        };
      };
    # Literal expectations catch a changed base grant or a missing/duplicated line.
    reminderBaseText = "Standing request from me, the user: you may use subagents, workflows, deep research and delegates whenever they fit, and by default hand bulk reading, measuring and edit-and-test loops to them; load the delegate-routing skill in that same turn to size their model and effort.";
    orchestratorLine = "I want this session kept interactive: hand off assigned work or questions you cannot answer quickly before gathering quick facts; send sweeps, including design, to a workflow when available, otherwise to native subagents.";
    orchestratorOff = change {ai.programs.delegate-routing.routing."Orchestrator session".enable = false;};
    orchestratorRuntimeOff = runtime:
      change {ai.programs.delegate-routing.runtimes.${runtime}.routing."Orchestrator session".enable = false;};
    orchestratorRuntimeText = runtime:
      change {
        ai.programs.delegate-routing = {
          routing."Orchestrator session".enable = false;
          runtimes.${runtime}.routing."Orchestrator session" = {
            enable = true;
            text = "I want runtime guidance\nkept in one line.\n\nDetails stay in the rule.";
          };
        };
      };
    reminderCustomText = "CUSTOM REMINDER: \"delegate\"\nsecond line";
    reminderCustom = change {ai.programs.delegate-routing.reminder.text = reminderCustomText;};
    reminderSourcePath = ../fragments/orchestrator-session.md;
    reminderSource = change {ai.programs.delegate-routing.reminder.source = reminderSourcePath;};
    reminderWarning = messages: lib.any (lib.hasInfix "hooks.delegate-routing-reminder.action.prompt") messages;
    reminderWithIgnoredPrompt = change {ai.kiro.hooks.delegate-routing-reminder.action.prompt.text = "IGNORED PROMPT";};
    manualScenario.ai = {
      claude.enable = true;
      kiro.cli.enable = true;
      programs.delegate-routing.runtimes.claude = {
        enable = true;
        manualExternalDelegates = ["kiro"];
      };
    };
    manualMissingModels = evaluate manualScenario;
    manualManaged = evaluate (lib.recursiveUpdate manualScenario {
      ai.programs.delegate-routing.runtimes.kiro.models = [{vendors = ["anthropic"];}];
    });
    manualOverlap = evaluate (lib.recursiveUpdate manualScenario {
      ai.programs.delegate-routing.runtimes.claude.extraRuntimes = ["kiro"];
      ai.programs.delegate-routing.runtimes.kiro.models = [{vendors = ["anthropic"];}];
    });
    manualRuntimeDisabled = evaluate (lib.recursiveUpdate manualScenario {
      ai.kiro.cli.enable = lib.mkForce false;
      ai.programs.delegate-routing.runtimes.kiro.models = [{vendors = ["anthropic"];}];
    });
    invalid = evaluate (lib.recursiveUpdate manualScenario {
      ai = {
        kiro.cli.enable = lib.mkForce false;
        programs.delegate-routing.runtimes.claude = {
          extraRuntimes = ["kiro"];
          manualExternalDelegates = [];
        };
        programs.delegate-routing.runtimes.kiro.models = [{vendors = ["anthropic"];}];
      };
    });
    # A runtime with no default selection must choose one when its program and
    # runtime are enabled, and needs none once either is off and Claude no
    # longer names it.
    requiresSelection = target: let
      unnamed.ai.programs.delegate-routing.runtimes.claude.manualExternalDelegates =
        lib.remove target scenario.ai.programs.delegate-routing.runtimes.claude.manualExternalDelegates;
    in
      failsWith (change {ai.programs.delegate-routing.runtimes.${target}.models = [];}) "ai.programs.delegate-routing.runtimes.${target}.models must select at least one"
      && passes (change (lib.recursiveUpdate (lib.recursiveUpdate unnamed (setEnable target (lib.mkForce false))) {
        ai.programs.delegate-routing.runtimes.${target}.models = [];
      }))
      && passes (change (lib.recursiveUpdate unnamed {
        ai.programs.delegate-routing.runtimes.${target} = {
          enable = false;
          models = [];
        };
      }));
    extraProgramDisabledKiroMissingModels = change {
      ai = {
        programs.delegate-routing.runtimes.claude = {
          extraRuntimes = ["kiro"];
          manualExternalDelegates = [];
        };
        programs.delegate-routing.runtimes.kiro = {
          enable = false;
          models = [];
        };
      };
    };
    extraProgramDisabledKiro = change {
      ai = {
        programs.delegate-routing.runtimes.claude = {
          extraRuntimes = ["kiro"];
          manualExternalDelegates = [];
        };
        programs.delegate-routing.runtimes.kiro = {
          enable = false;
          models = [{vendors = ["anthropic"];}];
        };
      };
    };
    selector = value: change {ai.programs.delegate-routing.runtimes.claude.models = [value];};
    familyOverride = skill {ai.programs.delegate-routing.families.anthropic.opus.useFor = "CUSTOM OPUS TASK";};
    addedFamily = skill {
      ai = {
        programs.delegate-routing.families.example.x = {
          match = "example-x-*";
          tier = "strong";
          useFor = "CUSTOM FAMILY TASK";
        };
        programs.delegate-routing.runtimes.claude.models = [{families = ["x"];}];
      };
    };
    disabledNode = skill {ai.programs.delegate-routing.runtimes.claude.techniques.Agent.enable = false;};
    modifiedNode = skill {ai.programs.delegate-routing.runtimes.codex.techniques."codex exec".command = "CUSTOM CODEX COMMAND";};
    ownSubagentsOverride = skill {ai.programs.delegate-routing.runtimes.codex.techniques."codex exec".runsOwnSubagents = "CUSTOM OWN SUBAGENTS";};
    invalidNode = node: change {ai.programs.delegate-routing.runtimes.claude.techniques.Invalid = node;};
    # Family Launch cells name techniques, so match the technique table's own
    # row shape rather than any line mentioning the technique.
    techniqueRow = text: technique: lib.findFirst (lib.hasPrefix "| `${technique}` ") "" (lib.splitString "\n" text);
    kiroInvoke = techniqueRow kiro "invoke_sub_agent";
    # Technique, kind, pins model, pins effort and modes, without table padding.
    techniqueCells = text: technique: lib.sublist 1 5 (map lib.trim (lib.splitString "|" (techniqueRow text technique)));
    # The "Runs own subagents" cell, which follows Modes.
    ownSubagents = text: technique: lib.trim (builtins.elemAt (lib.splitString "|" (techniqueRow text technique)) 6);
    ruleText = value: value.config.ai.claude.rules.delegate-routing-router.text;
    ordered = text: names: let
      headings = lib.filter (line: lib.hasPrefix "### " line) (lib.splitString "\n" text);
      selected = lib.filter (line: lib.elem (lib.removePrefix "### " line) names) headings;
    in
      selected == map (entry: "### ${entry}") names;
    routingDefaults = result.config.ai.programs.delegate-routing.routing;
    routingDisabled = change {ai.programs.delegate-routing.routing."Size the work".enable = false;};
    routingReplaced = change {ai.programs.delegate-routing.routing."Follow the user's request".text = "CUSTOM REQUEST GUIDANCE";};
    routingInserted = change {
      ai.programs.delegate-routing.routing."Consumer guidance" = {
        after = ["Size the work" "Missing anchor"];
        before = ["Choose execution"];
        text = "CUSTOM INSERTED GUIDANCE";
      };
    };
    runtimeRouting = change {
      ai.programs.delegate-routing = {
        routing."Portable guidance" = {
          always = true;
          text = "PORTABLE GUIDANCE";
        };
        runtimes.claude.routing = {
          "Portable guidance".text = "CLAUDE GUIDANCE";
          "Size the work".enable = false;
        };
      };
    };
    workflowName = "Work and review";
    workflowHeader = "Use when a delegate makes a change someone will act on";
    # A runtime record turns the enabled-by-default entry off for its own
    # runtime only; sibling runtimes keep the shipped default.
    runtimeCatalogDisabled = change {
      ai.programs.delegate-routing.runtimes.claude.routing."Orchestrator session".enable = false;
    };
    # A runtime workflow record that sets no text keeps the portable header.
    runtimeWorkflowStep = change {
      ai.programs.delegate-routing.runtimes.claude.workflows.${workflowName}.steps."Claude step" = {
        after = ["Loop"];
        text = "CLAUDE WORKFLOW STEP";
      };
    };
    runtimeCatalogHeader = change {
      ai.programs.delegate-routing.runtimes.claude.workflows.${workflowName}.text = "CLAUDE CATALOG INTRO";
    };
    catalogOverridden = change {
      ai.programs.delegate-routing.routing."Orchestrator session".text = "CUSTOM ORCHESTRATOR GUIDANCE";
    };
    catalogDisabled = change {
      ai.programs.delegate-routing.routing."Orchestrator session".enable = false;
    };
    # Every always-on entry off removes the rule; fails if a shipped always
    # entry stays on after a consumer disables the set.
    alwaysDisabled = change {
      ai.programs.delegate-routing.routing = {
        "Load delegate-routing".enable = false;
        "Orchestrator session".enable = false;
        "Pool drain".enable = false;
        "Validate the result".enable = false;
      };
    };
    workflowInserted = change {
      ai.programs.delegate-routing.workflows.${workflowName}.steps."Consumer step" = {
        after = ["Rubric"];
        before = ["Review"];
        text = "CUSTOM WORKFLOW STEP";
      };
    };
    runtimeWorkflow = change {
      ai.programs.delegate-routing = {
        workflows.Consumer = {
          always = true;
          text = "PORTABLE WORKFLOW INTRO";
          steps = {
            First.text = "PORTABLE FIRST STEP";
            Last = {
              after = ["First"];
              text = "PORTABLE LAST STEP";
            };
          };
        };
        runtimes.claude.workflows.Consumer = {
          text = "CLAUDE WORKFLOW INTRO";
          steps = {
            First.text = "CLAUDE FIRST STEP";
            Middle = {
              after = ["First"];
              before = ["Last"];
              text = "CLAUDE MIDDLE STEP";
            };
          };
        };
      };
    };
    runtimeWorkflowDisabled = change {
      ai.programs.delegate-routing.runtimes.claude.workflows.${workflowName}.enable = false;
    };
    disabledAnchor = change {
      ai.programs.delegate-routing.routing = {
        Anchor = {
          enable = false;
          after = ["Consumer"];
        };
        Consumer = {
          always = true;
          after = ["Anchor"];
          text = "DISABLED ANCHOR GUIDANCE";
        };
      };
    };
    selfCycle = edge:
      ruleText (change {
        ai.programs.delegate-routing.routing.Self = {
          always = true;
          ${edge} = ["Self"];
          text = "SELF CYCLE";
        };
      });
    selfCycleStep = edge:
      ruleText (change {
        ai.programs.delegate-routing.workflows.Self = {
          always = true;
          steps.Self = {
            ${edge} = ["Self"];
            text = "SELF STEP CYCLE";
          };
        };
      });
    cyclicRouting = change {
      ai.programs.delegate-routing.routing = {
        CycleA = {
          always = true;
          after = ["CycleB"];
          text = "CYCLE A";
        };
        CycleB = {
          always = true;
          after = ["CycleA"];
          text = "CYCLE B";
        };
      };
    };
    cyclicWorkflow = change {
      ai.programs.delegate-routing.workflows.Cycle = {
        always = true;
        steps = {
          CycleA = {
            after = ["CycleB"];
            text = "CYCLE A";
          };
          CycleB = {
            after = ["CycleA"];
            text = "CYCLE B";
          };
        };
      };
    };
    identicalContent = evaluate (lib.mkMerge [
      scenario
      {ai.programs.delegate-routing.routing.Conflict.text = "IDENTICAL CONTENT";}
      {ai.programs.delegate-routing.routing.Conflict.text = "IDENTICAL CONTENT";}
    ]);
    contentConflict = evaluate (lib.mkMerge [
      scenario
      {ai.programs.delegate-routing.routing.Conflict.text = "FIRST CONTENT";}
      {ai.programs.delegate-routing.routing.Conflict.text = "SECOND CONTENT";}
    ]);
    redact = import ../../../lib/redact {inherit lib;};
    usageBase.ai = {
      claude = {
        enable = true;
        skills.delegate-routing = null;
      };
      codex = {
        enable = true;
        skills.delegate-routing = null;
      };
      programs.delegate-routing.enable = true;
    };
    usageInstance = key: {
      clientKeys.usage-test = {
        key = redact.file "/run/secrets/client";
        routes = [{credential = "login";}];
      };
      credentials.login.oauth = {
        account = redact.file "/run/secrets/account";
        vendor = "claude";
      };
      settings.management.secret-key = key;
    };
    usageSelected.ai = {
      cliproxyapi.instances.main = usageInstance (redact.file "/run/secrets/management");
      settings.inference = {
        clientKey = "usage-test";
        instance = "main";
      };
    };
    usage = extra: evaluate (lib.mkMerge [usageBase extra]);
    usageVars = evaluation: runtime:
      lib.filterAttrs (key: _: lib.hasPrefix "DELEGATE_USAGE_CPA_" key)
      (
        if runtime == "claude"
        then evaluation.config.ai.claude.native.settings.env
        else evaluation.config.ai.${runtime}.environmentVariables
      );
    usageEmpty = extra: lib.all (runtime: usageVars (usage extra) runtime == {}) ["claude" "codex"];
    poolConfig = {
      families.anthropic.opus.pools = {
        claude = "measured";
        codex = "configured";
        kiro = "measured";
      };
      pools = {
        configured.window = {
          limit = 12.5;
          resetDay = 28;
          unit = "units";
        };
        measured = {
          description = "SHARED | BUDGET\nDESCRIPTION";
          usage = {
            runtime = "claude";
            technique = "pool-reader";
          };
        };
      };
      runtimes = {
        claude.techniques.pool-reader = {
          command = "read-pool --current";
          kind = "usage";
        };
        codex.models = [{families = ["opus"];}];
      };
    };
    goPoolWindow = {
      limit = 100;
      resetDay = 1;
      unit = "credits";
    };
    poolResult = change {ai.programs.delegate-routing = poolConfig;};
    poolSkill = readPlanner poolResult "claude";
    poolChange = settings: change {ai.programs.delegate-routing = lib.recursiveUpdate poolConfig settings;};
    # Print the actual diagnostic as evidence that rejection names the bad key.
    poolFailsWith = evaluation: expected: let
      failures = lib.filter (item: !item.assertion && lib.hasInfix expected item.message) evaluation.config.assertions;
    in
      failures != [] && builtins.trace (builtins.head failures).message true;
    poolReaderFails = settings:
      poolFailsWith (poolChange settings) "pools.measured.usage.technique: reference an enabled usage technique with a non-empty command.";
    poolWindowFails = window:
      !(builtins.tryEval (builtins.deepSeq (poolChange {pools.configured.window = window;}).config.ai.programs.delegate-routing.pools true)).success;
    routingFixture = poolChange {
      pools.outside.usage = {
        runtime = "kimchi";
        technique = "outside-reader";
      };
      runtimes = {
        claude = {
          extraRuntimes = ["codex" "kiro"];
          manualExternalDelegates = ["kiro"];
          models = [{families = ["flash" "opus"];}];
          techniques.Workflow.enable = false;
        };
        kimchi.techniques.outside-reader = {
          command = "read-outside --current";
          kind = "usage";
        };
      };
    };
    routingArgs = let
      portable = routingFixture.config.ai.programs.delegate-routing;
      selection = import ../lib/select-families.nix {inherit lib;};
    in {
      inherit lib;
      inherit (portable) families pools;
      inherit (portable.runtimes.claude) extraRuntimes manualExternalDelegates;
      models = lib.mapAttrs (_: settings: settings.models) portable.runtimes;
      runtime = "claude";
      techniques = selection.effectiveTechniques routingFixture.config;
    };
    routingView = import ../lib/routing-view.nix routingArgs;
    sessionPools = {
      claude = "claude";
      codex = "codex";
      kimchi = "kimchi-proxy";
      kiro = "kiro-proxy";
    };
    # Build each runtime's delivered skill on both backends with a registered fake
    # Reader, not a Python-authored manifest or a helper passthru shortcut.
    readerOutput = pkgs.writeText "routing-reader.json" (builtins.toJSON {
      account = {
        auth_index = null;
        name = "fixture";
        plan = null;
      };
      balances = [];
      bonuses = [];
      pool = "not-the-registration";
      windows.monthly = {
        remainingPercent = 50;
        resetsAt = "2026-12-01T00:00:00Z";
        status = "ok";
        usedPercent = 50;
        windowSeconds = 2592000;
      };
    });
    packagedHelperCases = {
      claude = {
        pool = "claude";
        technique = "Workflow";
      };
      codex = {
        pool = "codex";
        technique = "spawn_agent";
      };
      kimchi = {
        pool = "kimchi-proxy";
        technique = "Agent";
      };
      kiro = {
        pool = "kiro-proxy";
        technique = "run_workflow";
      };
    };
    packagedHelperDelivery = runtime:
      change {
        ai.kiro.cli.workflows.enable = true;
        ai.programs.delegate-routing = {
          families.fixture.packaged = {
            example.${runtime} = "fixture-model";
            match = "fixture-model";
            pools.${runtime} = sessionPools.${runtime};
            tier = "strong";
          };
          pools = lib.mkForce {
            ${sessionPools.${runtime}}.usage = {
              inherit runtime;
              technique = "fixture-reader";
            };
          };
          runtimes.${runtime} = {
            extraRuntimes = lib.mkForce [];
            manualExternalDelegates = lib.mkForce [];
            models = lib.mkForce [{vendors = ["fixture"];}];
            sessionPool = sessionPools.${runtime};
            techniques.fixture-reader = {
              command = "${pkgs.coreutils}/bin/cat ${readerOutput}";
              kind = "usage";
            };
          };
        };
      };
    sessionDelivery = change {
      ai.programs.delegate-routing = {
        pools = lib.genAttrs ["claude" "codex" "kimchi-proxy" "kiro-proxy"] (_: {
          window = {
            limit = 100;
            resetDay = 1;
            unit = "credits";
          };
        });
        runtimes = {
          claude.sessionPool = "claude";
          codex.sessionPool = "codex";
          kimchi.sessionPool = "kimchi-proxy";
          kiro.sessionPool = "kiro-proxy";
        };
      };
    };
    # Like mkWrapperGrepTest, realize the module output and inspect what ships.
    # Rejects a manifest with sessionPool = null even when skill prose is correct.
    packagedHelperCheck = runtime: let
      expected = packagedHelperCases.${runtime};
    in
      pkgs.runCommand "delegate-routing-${name}-${runtime}-packaged-helper" {
        # Read the delivered file with its store-reference context so the
        # advertised helper and manifest are inputs to this check's sandbox.
        expectedPool = expected.pool;
        expectedTechnique = expected.technique;
        passAsFile = ["skill"];
        inherit runtime;
        skill = readSkill (packagedHelperDelivery runtime) runtime;
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        ${pkgs.python3}/bin/python3 - <<'PYTHON'
        import json
        import os
        from pathlib import Path
        import re
        import subprocess

        runtime = os.environ["runtime"]
        expected_pool = os.environ["expectedPool"]
        technique = os.environ["expectedTechnique"]
        skill = Path(os.environ["skillPath"]).read_text()
        command = re.search(r"`(/nix/store/[^` ]+/bin/delegate-routing-plan) --role <role> --launch-context <json-path>`", skill)
        assert command, "delivered skill lacks the complete helper invocation"
        wrapper = Path(command[1])
        script = wrapper.read_text()
        manifest_path = re.search(r"--manifest (/nix/store/[^\s]+)", script)[1]
        manifest = json.loads(Path(manifest_path).read_text())
        context = Path("launch-context.json")
        context.write_text(json.dumps({
            "nonInteractive": True,
            "roles": {"writer": {"effort": "high", "families": {"packaged": {
                "avoidFor": "fixture has no exclusions", "fit": "fixture writer",
                "trial": "not a trial", "useFor": "fixture task",
            }}}},
            "techniques": [{"efforts": ["high"], "model": "fixture-model", "runtime": runtime, "technique": technique}],
        }))

        def check(executable):
            result = subprocess.run([str(executable), "--role", "writer", "--launch-context", str(context), "--now", "2026-11-15T00:00:00Z"], capture_output=True, text=True, check=True)
            output = json.loads(result.stdout)
            assert output["sessionPool"] == expected_pool, f"sessionPool must be {expected_pool}"
            assert output["runtime"] == runtime, output
            assert output["automaticRuntimes"] == [runtime], output
            assert output["snapshot"] == "2026-11-15T00:00:00+00:00", output
            assert output["pools"] == {expected_pool: {"buffer": 0.5, "pace": 0.9375, "status": "measured"}}, output
            candidates = output["roles"]["writer"]["candidates"]
            assert len(candidates) == 1, output
            expected = f"role=writer runtime={runtime} family=packaged technique={technique} model=fixture-model effort=high"
            assert candidates[0]["line"] == expected, output
            assert candidates[0]["pool"] == expected_pool, output
            assert candidates[0]["budget"] == "measured", output
            assert result.stderr.strip() == expected, result.stderr

        check(wrapper)
        # Reproduce the broken generated-manifest change with the same packaged
        # script and helper, changing only its manifest path to a writable copy.
        manifest["sessionPool"] = None
        broken_manifest = Path("broken-manifest.json").resolve()
        broken_manifest.write_text(json.dumps(manifest))
        broken_wrapper = Path("broken-wrapper").resolve()
        broken_wrapper.write_text(script.replace(manifest_path, str(broken_manifest)))
        broken_wrapper.chmod(0o700)
        try:
            check(broken_wrapper)
        except AssertionError as error:
            assert str(error) == f"sessionPool must be {expected_pool}", error
        else:
            raise AssertionError("sessionPool = null mutation escaped the packaged check")
        print("PASS: ${name}/${runtime} delivered skill -> wrapper -> manifest -> fake Reader; sessionPool = null rejected")
        PYTHON
        ${pkgs.coreutils}/bin/touch "$out"
      '';
  in {
    # Hand-written audience expectations reject planner-only orchestrator duties,
    # contradictory handoff orders for the planner, and lost worker policy in
    # each of the eight backend/runtime deliveries. Missing reviewer base briefs,
    # planner-only input rules and a dead steering pointer must also fail. Size
    # never proves placement.
    "module-delegate-routing-${name}-planner-context-delivery" = mkTest "delegate-routing-${name}-planner-context-delivery" (
      lib.all (runtime: let
        entry = readSkill result runtime;
        context = readPlanner result runtime;
        router = result.config.ai.${runtime}.rules.delegate-routing-router.text;
        orchestrator = router + "\n" + entry;
        baseline = {
          claude = 42559;
          codex = 39372;
          kimchi = 39743;
          kiro = 39769;
        };
        reference = builtins.head (builtins.match ".*`(/nix/store/[^`]+/PLANNER.md)`.*" (lib.replaceStrings ["\n"] [" "] entry));
      in
        builtins.readFile reference
        == context
        && (builtins.stringLength (readSkill sizeResult runtime) + builtins.stringLength sizeResult.config.ai.${runtime}.rules.delegate-routing-router.text) * 4 < (baseline.${runtime} + 5233) * 3
        && !(lib.hasInfix "| Family" entry)
        && !(lib.hasInfix "**Review:**" entry)
        && hasProse "must read that reference before planning" entry
        && hasProse "without reloading the planner reference for each delegate" entry
        && hasProse "does not recursively plan it" entry
        && lib.hasInfix "--role planner --launch-context <json-path>" entry
        && lib.hasInfix "--check-plan <plan-path>" entry
        && lib.hasInfix "validation.status = \"valid\"" entry
        # Fails if a result-only turn has no always-on duty to validate delegate claims.
        && lib.all (needle: hasProse needle router) [
          "Validate delegate results before passing them on, following Validate the result in the skill."
          "When someone steers how they should work, propose a change to their source"
          "the delegate-routing package's fragments"
          "its `ai.programs.delegate-routing` routing and workflows entries"
          "Do not edit a rendered rule or skill file"
          "do not record that steering in memory or as a house rule"
        ]
        && lib.all (needle: hasProse needle orchestrator) [
          "Reading what the user pointed at"
          "Hand off before investigating task source"
          "gather quick facts in this session only while that delegate runs"
          "Loading delegate-routing and running its usage reads before the launch are part of the handoff"
          "Hand bulk reading, searching, measuring, tracing, edit-and-test loops, file moves and document writing to delegates"
          "Stay on the current item until it is done or blocked"
          "only the output lines it cites"
          "Point the next delegate at a file path instead of pasting content"
          "Aim for every pool to reach its reset near empty"
          "Do not report pool numbers unless asked"
          "Say in every external launch brief that the delegate is non-interactive and reports to an orchestrator, not a person"
          "A non-interactive or external delegate does not launch external delegates"
          "If the user named a model, effort, runtime or tool for the task, use it"
          "isn't available, say so before using something else"
          "Name each role's model and effort in one line in the launch message"
          "When something fails, name why"
          "Bring the user only what is real and needs their decision"
          "When that entry is disabled, these rules apply instead"
          "answer a documented fact from the few files that decide it"
          "do a quick review from the few files that decide it, and fan out when that check shows the work is wide"
          "when unsure, do the in-session pass and offer the deeper one with its rough cost"
          "an interesting or security-adjacent subject alone is not a reason to fan out"
          "Every rubric carries these standing rows"
          "**Scope.**"
          "**Fixtures.**"
          "**Naming.**"
          "**Size.**"
          "**Callers.**"
          "**Same-change caller.**"
          "**Checks.**"
          "**Earliest layer.**"
          "**Necessity.**"
          "**One source of truth.**"
          "**Readable in one pass.**"
          "**Abstract on the third repeat.**"
          "**Data over control flow.**"
          "Paste the file verbatim into the worker's and every reviewer's brief"
          "Change a running delegate's task with a new brief rather than stopping it"
          "When a vendor's safety filter refuses a brief, route the task to another vendor"
          "An exit code of 0 alone isn't proof"
        ]
        && lib.all (needle: hasProse needle entry) [
          "Pin the review base before each loop's first write"
          "for a unit, HEAD before the unit starts"
          "for a fix round, HEAD before the fix starts"
          "for the branch-level review, HEAD before the branch's first write"
          "base..HEAD"
          "An accepted finding is fixed in the PR that introduced it"
          "re-pin each restacked PR's review base to its rewritten parent"
          "A separate PR that only carries fixes to other PRs' findings is a loop failure"
          "Stop early when no accepted issue is medium severity or higher"
          "up to 3 rounds per loop"
          "a fix round counts toward the loop it repairs"
          "If the same defect survives 2 rounds, change the brief"
          "At the cap, return the result, open defects and decision needed"
          "goes on the report's gap list, not into a fix"
          "Never split a change to get past the round cap"
          "never the orchestrator"
          "a different model family than the writer and the cut's proposer"
          "The orchestrator validates unresolved questions returned by the judge"
          "The planner prepares base briefs for every reviewer launch before returning the plan, including second-check and judge"
          "After the first check returns, the orchestrator adds the earlier checks' inputs to those base briefs before each reviewer launches"
          "Preserve the rubric and base policy"
          "**Second-check inputs:** include each issue that holds, its location and its rubric row or requirement, without the first check's reasoning, evidence or severity"
          "**Judge inputs:** include both checks' outcomes and evidence"
          "never earlier reasoning or arguments, proposed severity, round number, previous verdict, recurrence count or the writer's notes or account of fixes"
          "Use neutral briefs"
          "Send the writer only accepted issues, with location and severity"
          "The orchestrator briefs review as its own stage before writing starts"
          "A writer never launches or briefs its own reviewer"
          "Verify a claimed review by its artifact"
          "Each unit is reviewed by one check, from a vendor other than the writer's, before the next unit starts"
          "no review of the whole branch mid-stream"
          "When the units are done, the branch gets one branch-level review"
          "all three checks when the PR is going ready, one check in any earlier state"
          "the fix's diff plus what it touches, one check, never the whole branch again"
          "the orchestrator validates it, and a different delegate fixes against that diagnosis"
          "includes the number of files touched and a line breakdown by kind, as added and removed lines per kind"
          "hand-written code, counting shipped agent-instruction prose"
          "tests, fixtures and checks; generated content; docs; and pins or lockfiles when present"
        ]
        && lib.all (needle: hasProse needle context) [
          "The planner reads the resolved routing/workflow policy and task source once"
          "List the parts of the work before choosing execution"
          "Name the files each part writes and its dependencies"
          "Put at most ten simultaneous delegates in a wave"
          "A unit is a bounded change with one reader and one verification"
          "Every worker and every reviewer brief must include its complete text verbatim"
          "The planner prepares base briefs for every reviewer launch before returning the plan, including second-check and judge"
          "After the first check returns, the orchestrator adds the earlier checks' inputs to those base briefs before each reviewer launches"
          "To change any rule in delegate-routing for yourself"
          "Open every writer and fixer brief with a hard-rules block before the task"
          "A non-interactive or external delegate does not launch external delegates"
          "On a transient 5xx from a provider, rerun on another pool instead of looping"
        ]
        && (lib.hasInfix "## manual-only external delegates" entry == lib.hasInfix "## manual-only external delegates" context)
        && (!(lib.hasInfix "## manual-only external delegates" context) || hasProse "Not a candidate for auto-selection; use only when the user names it" entry)
        && !(hasProse "Build the second-check and judge briefs only after the first check returns" entry)
        && !(hasProse "Follow Load delegate-routing" context)
        # Input rules have one authoritative source and one copy per projection.
        && lib.all (text:
          lib.all (needle: builtins.length (lib.splitString needle text) == 2) [
            "**Second-check inputs:**"
            "**Judge inputs:**"
            "The planner prepares base briefs for every reviewer launch"
          ]) [entry context]
        && !(hasProse "When someone steers how they should work" entry)
        && !(hasProse "When someone steers how they should work" context)
        && !(hasProse "Hand off before investigating task source" context)
        && !(hasProse "Hand bulk reading" context)
        && !(hasProse "List the parts of the work before choosing execution" entry)
        && !(hasProse "compulsory execution constraints" orchestrator)
        && !(hasProse "compulsory execution constraints" context)
        && lib.hasInfix "| Family" context
        && lib.hasInfix "3. **Plan:**" context
        && lib.hasInfix "### Pool drain" context
        && lib.hasInfix "### Validate the result" context
        # Pool drain on/off legacy cases must change the orchestrator's input.
        && !(lib.hasInfix "Aim for every pool" (readSkill (change {ai.programs.delegate-routing.routing."Pool drain".enable = false;}) runtime))
        # Fallback stays delivered when the optional orchestrator rule is off.
        && hasProse "When that entry is disabled" (readSkill orchestratorOff runtime)
        # Changing always moves a router entry to the skill, rather than losing it.
        && hasProse "Hand off before investigating task source" (readSkill (change {ai.programs.delegate-routing.routing."Orchestrator session".always = false;}) runtime))
      runtimes
    );
    # Reject a missing no-planner warning, or bootstrap lists that include
    # small/mid families or omit a selected strong/frontier family.
    "module-delegate-routing-${name}-planner-bootstrap" = mkTest "delegate-routing-${name}-planner-bootstrap" (let
      bootstrapText = tiers: let
        rendered = readSkill (change {
          ai.programs.delegate-routing = {
            runtimes.claude = {
              extraRuntimes = [];
              manualExternalDelegates = [];
              models = [
                {
                  vendors = ["anthropic"];
                  inherit tiers;
                }
              ];
            };
            skill = {
              entries."Plan and launch".text = "BEGIN BOOTSTRAP\n\n{bootstrap}\n\nEND BOOTSTRAP";
              phrases."Planner candidate".text = "- {family}";
            };
          };
        }) "claude";
      in
        lib.trim (builtins.head (lib.splitString "END BOOTSTRAP" (builtins.elemAt (lib.splitString "BEGIN BOOTSTRAP" rendered) 1)));
    in
      bootstrapText ["mid" "small"]
      == "No configured strong/frontier planner reach; report a loop failure."
      && lib.splitString "\n" (bootstrapText ["frontier" "mid" "small" "strong"])
      == [
        "- fable (anthropic) `claude-fable-*`"
        "- opus (anthropic) `claude-opus-*`"
      ]);
    # Reject hard-coded default-only projection: disabled entries stay absent,
    # custom always-on entries and runtime replacements also reach the planner.
    "module-delegate-routing-${name}-planner-custom-context" = mkTest "delegate-routing-${name}-planner-custom-context" (let
      custom = change {
        ai.programs.delegate-routing = {
          routing = {
            "Custom execution" = {
              always = true;
              text = "CUSTOM EXECUTION POLICY";
            };
            "Size the work".enable = false;
          };
          skill.entries."Custom planner note".text = "CUSTOM PLANNER NOTE";
          runtimes.claude.routing."Custom execution".text = "RUNTIME EXECUTION POLICY";
        };
      };
    in
      lib.all (runtime: let
        text = readPlanner custom runtime;
      in
        lib.hasInfix "CUSTOM PLANNER NOTE" text
        && !(lib.hasInfix "### Size the work" text)
        && lib.hasInfix (
          if runtime == "claude"
          then "RUNTIME EXECUTION POLICY"
          else "CUSTOM EXECUTION POLICY"
        )
        text
        && !(lib.hasInfix (
            if runtime == "claude"
            then "CUSTOM EXECUTION POLICY"
            else "RUNTIME EXECUTION POLICY"
          )
          text))
      runtimes);
    "module-delegate-routing-${name}-claude-packaged-helper" = packagedHelperCheck "claude";
    "module-delegate-routing-${name}-codex-packaged-helper" = packagedHelperCheck "codex";
    "module-delegate-routing-${name}-kimchi-packaged-helper" = packagedHelperCheck "kimchi";
    "module-delegate-routing-${name}-kiro-packaged-helper" = packagedHelperCheck "kiro";
    # Fails if common-module delivery drops sessionPool or renders another
    # runtime's identity or pool. All four skills are supported on both
    # backends; HM Kimchi's reminder-hook exclusion does not exclude its skill.
    "module-delegate-routing-${name}-session-pool-delivery" = mkTest "delegate-routing-${name}-session-pool-delivery" (
      passes sessionDelivery
      && lib.all (runtime: lib.hasInfix "Runtime: ${runtime}; session pool: ${sessionPools.${runtime}}." (readSkill sessionDelivery runtime)) runtimes
    );
    # Rejects manual Reader discovery/arithmetic, runtime-specific shared rules,
    # lost buffer/unknown policy, an under-tier review fallback or unnamed launches.
    "module-delegate-routing-${name}-helper-policy-contract" = mkTest "delegate-routing-${name}-helper-policy-contract" (
      lib.all (text: hasProse text claude || throw "missing planner policy: ${text}") [
        "invoke the absolute `delegate-routing-plan` command rendered in this runtime's skill"
        "Use its decision as canonical"
        "run the Reader of every registered pool listed in its output"
        "worst-window pace"
        "a monthly pool is paced against its month, not the week"
        "minimum remaining share across applicable windows is strictly more than a fifth"
        "every other fitting measured pool is behind or level in pace"
        "unknown session identity cannot certify it"
        "With no measurable fitting pool, use fit alone"
        "Never treat exhaustion as unmeasured"
        "Aim for every pool to reach its reset near empty"
        "Do not report pool numbers unless asked"
        "never step down a tier; report a loop failure"
      ]
      && !(lib.hasInfix "remaining share divided by" stub)
      && !(lib.hasInfix "/bin/delegate-routing-plan" stub)
      && lib.all (runtime: let
        text = readPlanner sessionDelivery runtime;
      in
        sessionDelivery.config.ai.${runtime}.rules.delegate-routing-router.text
        == sessionDelivery.config.ai.claude.rules.delegate-routing-router.text
        && lib.hasInfix "/bin/delegate-routing-plan --role <role> --launch-context <json-path>" text
        && (hasProse "It enforces the strong/frontier floor before pool ranking" text || throw "missing ${runtime} review floor")
        && hasProse "never step down a tier; report a loop failure" text
        && lib.all (launch: hasProse launch text || throw "missing ${runtime} review fallback: ${launch}") [
          "Agent calls that name a generated agent"
          "Workflow tool's agent"
          "`claude -p`"
          "`codex exec`"
        ])
      runtimes
    );
    # Fails if automatic routes admit a disabled technique, unresolved agent,
    # manual-only target or another harness's native tool; reader inventory
    # must still include a registered runtime outside all launch targets.
    # Hiding launch prose must not bypass missing model-spelling rejection.
    "module-delegate-routing-${name}-routing-view" = mkTest "delegate-routing-${name}-routing-view" (
      let
        text = readPlanner routingFixture "claude";
        routes =
          map (route: {
            family = route.family.name;
            inherit (route) pool target;
            techniques = map (technique: technique.name) route.techniques;
          })
          routingView.routes;
        resolved = import ../lib/routing-view.nix (routingArgs
          // {
            # A module-supplied picker resolution must beat catalog fallback.
            resolvedAgentFiles.opus = {
              family.defaultEffort = "high";
              id = "proxy-opus-123";
            };
          });
        agent = builtins.head (builtins.head resolved.routes).techniques;
      in
        passes routingFixture
        && routingView.runtimes == ["claude" "codex"]
        && routes
        == [
          {
            family = "opus";
            pool = "measured";
            target = "claude";
            techniques = ["Agent with generated agent file" "claude -p"];
          }
          {
            family = "opus";
            pool = "configured";
            target = "codex";
            techniques = ["codex exec"];
          }
          {
            family = "flash";
            pool = null;
            target = "claude";
            techniques = ["claude -p"];
          }
        ]
        && routingView.manualRoutes != []
        && lib.all (route: route.target == "kiro") routingView.manualRoutes
        && map (reader: {inherit (reader) command name;}) routingView.readers
        == [
          {
            command = null;
            name = "configured";
          }
          {
            command = "read-pool --current";
            name = "measured";
          }
          {
            command = "read-outside --current";
            name = "outside";
          }
        ]
        && agent.model
        == {
          isPattern = false;
          value = "proxy-opus-123";
        }
        && agent.agent.family.defaultEffort == "high"
        && (builtins.head (lib.last routingView.routes).techniques).model
        == {
          isPattern = true;
          value = "test-flash-*";
        }
        && lib.hasInfix "claude: `claude -p` with full model id the highest id matching `test-flash-*`" text
        && lib.hasInfix "claude: `Agent with generated agent file` with the generated agent file pinning `claude-opus-5-5`, else `claude -p`" text
        && !(lib.hasInfix "`Workflow`" text)
        && !(lib.hasInfix "via kiro:" text)
        && hasProse "| outside | `read-outside --current` | measured |" text
        && !(lib.hasInfix "**outside-reader (usage):**" text)
        && skillFails {
          ai.programs.delegate-routing = {
            runtimes.claude.techniques."claude -p".modelArg = "";
            skill.phrases."Launch route".enable = false;
          };
        }
    );
    # Fails on lexical ordering, catalog-only resolution, missing pins, or a
    # route advertised when its family has no delivered agent file.
    "module-delegate-routing-${name}-agent-files" = mkTest "delegate-routing-${name}-agent-files" (
      let
        agents = result.config.ai.claude.agents;
        resolver = import ../lib/agent-files.nix {inherit lib;};
        off = change {ai.programs.delegate-routing.runtimes.claude.techniques."Agent with generated agent file".enable = false;};
        missing = change {ai.programs.delegate-routing.runtimes.claude.models = [{families = ["flash"];}];};
        example = change {ai.programs.delegate-routing.families.anthropic.opus.example.claude = "claude-opus-4.6";};
        glmExample = change {
          ai.programs.delegate-routing = {
            families.zhipu.glm = {
              example.claude = "glm-5.3";
              match = "glm-*";
              tier = "strong";
            };
            runtimes.claude.models = [{families = ["glm"];}];
          };
        };
        programOff = change {ai.programs.delegate-routing.runtimes.claude.enable = false;};
        runtimeOff = change {ai.claude.enable = lib.mkForce false;};
        picker = change {
          ai = {
            internal.inferenceInstances.test = {
              backend = "cliproxyapi";
              url = "http://127.0.0.1:8317";
              clients.reader = {
                key = redact.file "/run/secrets/client";
                credentials = [
                  {
                    name = "test";
                    models = ["glm-5.3"];
                  }
                ];
              };
            };
            claude.settings.inference = {
              instance = "test";
              clientKey = "reader";
            };
            programs.delegate-routing = {
              families.zhipu.glm = {
                match = "glm-[0-9]*.[0-9]";
                tier = "strong";
              };
              runtimes.claude.models = [{families = ["glm"];}];
            };
          };
        };
      in
        lib.all (family: agents ? ${family}) ["fable" "haiku" "opus" "sonnet"]
        && techniqueCells claude "Agent with generated agent file" == ["`Agent with generated agent file`" "subagent" "true" "true" "interactive+headless"]
        && ownSubagents claude "Agent with generated agent file" == "supported (headless)"
        && lib.hasInfix "delegate-routing is the skill that authorizes setting effort" claude
        && lib.hasInfix "existing lower-precedence fallback, not a launch route" claude
        && lib.hasInfix "model: \"claude-opus-5-5\"" agents.opus
        && lib.hasInfix "effort: \"medium\"" agents.opus
        && lib.hasInfix "name: \"opus\"" agents.opus
        && lib.hasInfix "model: \"claude-fable-5-1\"" agents.fable
        && lib.hasInfix "effort: \"medium\"" agents.fable
        && lib.hasInfix "model: \"claude-sonnet-5-5\"" agents.sonnet
        && lib.hasInfix "effort: \"medium\"" agents.sonnet
        && lib.hasInfix "model: \"claude-haiku-5-5\"" agents.haiku
        && !(lib.hasInfix "effort:" agents.haiku)
        && lib.hasInfix "model: \"claude-opus-4.6\"" example.config.ai.claude.agents.opus
        # Numeric segment order: 10 > 9, 5-1 > 5, 6.1 > 6 > 5.6, and zero-padded
        # dated segments compare as numbers instead of aborting.
        && lib.all (case:
          (resolver.resolve case.ids [
            {
              name = "t";
              inherit (case) match;
              example = {};
            }
          ]).t.id
          == case.expected) [
          {
            ids = ["test-m-9" "test-m-10"];
            match = "test-m-*";
            expected = "test-m-10";
          }
          {
            ids = ["t-5" "t-5-1"];
            match = "t-*";
            expected = "t-5-1";
          }
          {
            ids = ["t-6.1" "t-5.6" "t-6"];
            match = "t-*";
            expected = "t-6.1";
          }
          {
            ids = ["t-2024-08-06" "t-2024-09-01"];
            match = "t-*";
            expected = "t-2024-09-01";
          }
        ]
        && lib.all (family: result.config.ai.files ? ${".claude/agents/${family}.md"}) ["fable" "haiku" "opus" "sonnet"]
        && !(result.config.ai.agents ? opus)
        && lib.hasInfix "model: \"glm-5.3\"" glmExample.config.ai.claude.agents.glm
        && programOff.config.ai.claude.agents == {}
        && runtimeOff.config.ai.claude.agents == {}
        && off.config.ai.claude.agents == {}
        && lib.hasInfix "claude: `Workflow` with full model id the highest id matching `claude-opus-*`" (readPlanner off "claude")
        && missing.config.ai.claude.agents == {}
        && lib.hasInfix "claude: `Workflow` with full model id the highest id matching `test-flash-*`" (readPlanner missing "claude")
        && lib.hasInfix "model: \"glm-5.3\"" picker.config.ai.claude.agents.glm
        && lib.hasInfix "claude: `Agent with generated agent file` with the generated agent file pinning `glm-5.3`" (readPlanner picker "claude")
        && result.config.ai.programs.delegate-routing.families.anthropic.opus.defaultEffort == "medium"
        && result.config.ai.programs.delegate-routing.families.anthropic.haiku.defaultEffort == null
        && !(builtins.tryEval (builtins.deepSeq (change {ai.programs.delegate-routing.families.anthropic.opus.defaultEffort = "invalid";}).config.ai.programs.delegate-routing.families true)).success
    );
    # Reject missing delivery, mkDefault list replacement, and an entry mkForce cannot replace.
    "module-delegate-routing-${name}-workflow-resume-settings" = mkTest "delegate-routing-${name}-workflow-resume-settings" (let
      directories = evaluation: evaluation.config.ai.claude.native.settings.permissions.additionalDirectories;
      consumer = change {ai.claude.native.settings.permissions.additionalDirectories = ["/opt/other"];};
      forced = change {ai.claude.native.settings.permissions.additionalDirectories = lib.mkForce ["/opt/only"];};
    in
      directories result
      == ["~/.claude/projects"]
      && lib.sort builtins.lessThan (directories consumer) == ["/opt/other" "~/.claude/projects"]
      && directories forced == ["/opt/only"]);
    # Reject unconditional writes and a notice naming a nonexistent package wrapper.
    "module-delegate-routing-${name}-workflow-resume-gates" = mkTest "delegate-routing-${name}-workflow-resume-gates" (let
      hooks = evaluation: evaluation.config.ai.claude.hooks.SessionStart or [];
      fallback = evaluation: evaluation.config.ai.claude.untrustedProjectAdditionalDirectories or [];
      directories = evaluation: let
        value = evaluation.config.ai.claude.native.settings.permissions.additionalDirectories or null;
      in
        if value == null
        then []
        else value;
      off = [
        (change {ai.programs.delegate-routing.runtimes.claude.techniques.Workflow.enable = false;})
        (change {ai.claude.enable = lib.mkForce false;})
        (change {ai.programs.delegate-routing.enable = false;})
      ];
      noPackage = change {ai.claude.package = null;};
      forcedFallback = change {ai.claude.untrustedProjectAdditionalDirectories = lib.mkForce ["/somewhere"];};
      consumer = change {ai.claude.hooks.SessionStart = [{hooks = [{command = "/consumer-hook";}];}];};
    in
      lib.all (evaluation: directories evaluation == [] && fallback evaluation == [] && hooks evaluation == []) off
      && directories noPackage == ["~/.claude/projects"]
      && fallback noPackage == []
      && hooks noPackage == []
      && (
        if name == "hm"
        then
          !(lib.hasAttrByPath ["ai" "claude" "untrustedProjectAdditionalDirectories"] result.options)
          && hooks result == []
        else
          fallback result
          == ["~/.claude/projects"]
          && builtins.length (hooks result) == 1
          && lib.hasInfix "delegate-routing-workflow-resume" (builtins.head (builtins.head (hooks result)).hooks).command
          && builtins.length (hooks consumer) == 2
          && fallback forcedFallback == ["/somewhere"]
          && hooks forcedFallback == []
      ));
    # Reject notes omitted from the delivered Claude technique table.
    "module-delegate-routing-${name}-workflow-resume-notes" = mkTest "delegate-routing-${name}-workflow-resume-notes" (
      hasProse "pass `args` again on resume" claude
      && hasProse "keep the working directory fixed for a run" claude
    );
    "module-delegate-routing-${name}-pools-bindings" = mkTest "delegate-routing-${name}-pools-bindings" (
      poolFailsWith (poolChange {families.anthropic.opus.pools.claude = "missing";}) "families.anthropic.opus.pools.claude: unknown pool `missing`"
      && poolFailsWith (poolChange {families.anthropic.opus.pools.unknown = null;}) "families.anthropic.opus.pools.unknown: `unknown` is not a runtime"
      && lib.hasInfix "claude: `Agent with generated agent file` with the generated agent file pinning `claude-opus-5-5`, else `Workflow` with full model id the highest id matching `claude-opus-*`, else `claude -p` with full model id the highest id matching `claude-opus-*`; via codex: `codex exec` with slug the highest id matching `claude-opus-*` (pool configured)" (readPlanner (poolChange {families.anthropic.opus.pools.claude = null;}) "claude")
    );
    "module-delegate-routing-${name}-pools-empty" = mkTest "delegate-routing-${name}-pools-empty" (
      result.config.ai.programs.delegate-routing.pools
      == {}
      && lib.all (runtime:
        !(lib.hasInfix "## Pools" (readPlanner result runtime))
        && withoutHelperPath (readPlanner result runtime)
        == withoutHelperPath (readPlanner (change {
            ai.programs.delegate-routing = {
              families.anthropic.opus.pools.claude = null;
              pools = {};
            };
          })
          runtime))
      runtimes
      && lib.all (family: family.pools == {}) ((import ../lib/select-families.nix {inherit lib;}).flatten result.config.ai.programs.delegate-routing.families)
    );
    "module-delegate-routing-${name}-pools-reader-assertions" = mkTest "delegate-routing-${name}-pools-reader-assertions" (
      poolReaderFails {runtimes.claude.techniques.pool-reader.enable = false;}
      && poolReaderFails {runtimes.claude.techniques.pool-reader.kind = "introspect";}
      && poolReaderFails {runtimes.claude.techniques.pool-reader.command = null;}
      && poolReaderFails {runtimes.claude.techniques.pool-reader.command = "";}
      && poolReaderFails {runtimes.claude.techniques.pool-reader.command = " \n ";}
      && poolReaderFails {pools.measured.usage.technique = "missing";}
      && poolFailsWith (change {
        ai = {
          claude.enable = lib.mkForce false;
          programs.delegate-routing = poolConfig;
        };
      }) "pools.measured.usage.runtime: the reader runtime must be enabled"
      && poolFailsWith (poolChange {pools.empty = {};}) "pools.empty: set usage or window"
    );
    "module-delegate-routing-${name}-pools-reader-environment" = mkTest "delegate-routing-${name}-pools-reader-environment" (
      usageVars (usage (lib.recursiveUpdate usageSelected {
        ai.programs.delegate-routing.pools.measured.usage = {
          runtime = "codex";
          technique = "usage";
        };
      })) "claude"
      == lib.foldl' (environment: runtime:
        environment
        // {
          "DELEGATE_USAGE_CPA_${lib.toUpper runtime}_MANAGEMENT_KEY_FILE" = "/run/secrets/management";
          "DELEGATE_USAGE_CPA_${lib.toUpper runtime}_URL" = "http://127.0.0.1:8317";
        }) {} ["claude" "codex"]
    );
    "module-delegate-routing-${name}-pools-render" = mkTest "delegate-routing-${name}-pools-render" (
      let
        compact = text: lib.concatStringsSep " " (lib.filter (part: part != "") (lib.splitString " " (lib.replaceStrings ["\n"] [" "] text)));
        text = compact poolSkill;
        window = poolResult.config.ai.programs.delegate-routing.pools.configured.window;
      in
        passes poolResult
        && lib.hasInfix "## Pools" text
        && lib.hasInfix "| Name | Reader | Measure | Description |" text
        && lib.hasInfix "| configured | none | configured: 12.500000 units per month, resets day 28; current use unknown | |" text
        && lib.hasInfix "| measured | `read-pool --current` | measured | SHARED \\| BUDGET DESCRIPTION |" text
        && lib.hasInfix "**pool-reader (usage):** `read-pool --current`" text
        && lib.hasInfix "claude: `Agent with generated agent file` with the generated agent file pinning `claude-opus-5-5`, else `Workflow` with full model id the highest id matching `claude-opus-*`, else `claude -p` with full model id the highest id matching `claude-opus-*` (pool measured); via codex: `codex exec` with slug the highest id matching `claude-opus-*` (pool configured)" text
        && lib.hasInfix "- opus (anthropic) `claude-opus-*`: `kiro-cli chat` with model_id the highest id matching `claude-opus-*` (pool measured)" text
        && lib.hasInfix "codex: `spawn_agent` with slug the highest id matching `claude-opus-*`, else `codex exec` with slug the highest id matching `claude-opus-*` (pool configured)" (readPlanner poolResult "codex")
        && builtins.length (lib.splitString "## Pools" (builtins.head (lib.splitString "### frontier" poolSkill))) == 2
        && withoutHelperPath (readPlanner (poolChange {pools.measured.window = window;}) "claude") == withoutHelperPath poolSkill
        && ruleText poolResult == stub
        && poolResult.config.ai.programs.delegate-routing.pools.configured.description == ""
        && poolResult.config.ai.programs.delegate-routing.pools.configured.usage == null
        && poolResult.config.ai.programs.delegate-routing.pools.measured.window == null
    );
    "module-delegate-routing-${name}-pools-window-type" = mkTest "delegate-routing-${name}-pools-window-type" (
      poolWindowFails {resetDay = 29;}
      && poolWindowFails {resetDay = 0;}
      && poolWindowFails {resetDay = 1.5;}
      && poolWindowFails {limit = "invalid";}
      && poolWindowFails {unit = 1;}
      && passes (poolChange {pools.configured.window.resetDay = 1;})
    );
    "module-delegate-routing-${name}-usage" = mkTest "delegate-routing-${name}-usage" (
      lib.all (runtime:
        usageVars (usage usageSelected) runtime
        == {
          "DELEGATE_USAGE_CPA_${lib.toUpper runtime}_MANAGEMENT_KEY_FILE" = "/run/secrets/management";
          "DELEGATE_USAGE_CPA_${lib.toUpper runtime}_URL" = "http://127.0.0.1:8317";
        }) ["claude" "codex"]
      && usageEmpty {}
      && usageEmpty {ai.cliproxyapi.instances = usageSelected.ai.cliproxyapi.instances;}
      && usageEmpty (lib.recursiveUpdate usageSelected {ai.programs.delegate-routing.enable = lib.mkForce false;})
      && usageEmpty (lib.mkMerge [
        usageSelected
        {
          ai.cliproxyapi.instances.main.settings.management.secret-key = lib.mkForce (redact.command "/run/read-management");
        }
      ])
    );
    "module-delegate-routing-${name}-content" = mkTest "delegate-routing-${name}-content" (
      passes result
      && lib.all (family: lib.hasInfix "${family} (anthropic)" nativeClaude) ["fable" "haiku" "opus" "sonnet"]
      && lib.hasInfix "claude: `Agent with generated agent file` with the generated agent file pinning `claude-opus-5-5`, else `Workflow` with full model id the highest id matching `claude-opus-*`, else `claude -p` with full model id the highest id matching `claude-opus-*`" nativeClaude
      && !(lib.hasInfix "(openai)" nativeClaude)
      && lib.all (family: lib.hasInfix "${family} (openai)" claude) ["astra" "luna" "sol" "terra"]
      && lib.hasInfix "via codex: `codex exec` with slug the highest id matching `gpt-*-sol`" claude
      && lib.hasInfix "(openai)" codex
      && !(lib.hasInfix "(anthropic)" codex)
      && lib.hasInfix "## manual-only external delegates" claude
      && lib.hasInfix "Not a candidate for auto-selection; use only when the user names it." claude
      && lib.hasInfix "claude-opus-*" claude
      && lib.hasInfix "gpt-*-sol" claude
    );
    # A launch route must name every enabled technique pinning model and effort,
    # in kind order, so a renderer that names only the first technique, an
    # inheriting technique, an in-harness tool of another runtime, no spelling at
    # all, or the old ambiguous "native (pool)" reach fails here. The no-native
    # guard reads a pools-bound scenario: the old renderer emitted
    # "native (pool)" only there. A reach into a harness with no enabled
    # technique pinning model and effort is refused too.
    "module-delegate-routing-${name}-launch-routes" = mkTest "delegate-routing-${name}-launch-routes" (
      let
        noWorkflow = skill {ai.programs.delegate-routing.runtimes.claude.techniques.Workflow.enable = false;};
        withExample = skill {ai.programs.delegate-routing.families.anthropic.opus.example.claude = "claude-opus-4.6";};
        glm = skill {
          ai.programs.delegate-routing = {
            families.zhipu.glm = {
              example.claude = "glm-5.3";
              match = "glm-*";
              pools.claude = "zai-coding";
              tier = "strong";
              useFor = "TEST GLM";
            };
            pools.zai-coding.window = {
              limit = 100;
              resetDay = 1;
              unit = "credits";
            };
            runtimes.claude.models = [{families = ["glm"];}];
          };
        };
      in
        lib.hasInfix "claude: `Agent with generated agent file` with the generated agent file pinning `claude-opus-5-5`, else `Workflow` with full model id the highest id matching `claude-opus-*`, else `claude -p` with full model id the highest id matching `claude-opus-*`" nativeClaude
        && lib.hasInfix "codex: `spawn_agent` with slug the highest id matching `gpt-*-astra`, else `codex exec` with slug the highest id matching `gpt-*-astra`" codex
        && !(lib.hasInfix "claude: `Agent`" nativeClaude)
        && lib.hasInfix "via codex: `codex exec` with slug the highest id matching `gpt-*-astra`" claude
        && !(lib.hasInfix "via codex: `spawn_agent`" claude)
        && lib.hasInfix "kiro: `kiro-cli chat` with model_id the highest id matching `claude-opus-*`" kiro
        && lib.hasInfix "kimchi: `Agent` with `--list-models` id the highest id matching `test-flash-*`" kimchi
        && lib.hasInfix "claude: `Agent with generated agent file` with the generated agent file pinning `claude-opus-5-5`, else `claude -p` with full model id the highest id matching `claude-opus-*`" noWorkflow
        && lib.hasInfix "claude: `Agent with generated agent file` with the generated agent file pinning `claude-opus-4.6`, else `Workflow` with full model id `claude-opus-4.6`" withExample
        && !(lib.hasInfix "claude: `Agent with generated agent file` with the generated agent file pinning `claude-opus-5-5`, else `Workflow` with full model id the highest id matching `claude-opus-*`" withExample)
        && lib.hasInfix "glm (zhipu) `glm-*`" glm
        && lib.hasInfix "claude: `Agent with generated agent file` with the generated agent file pinning `glm-5.3`, else `Workflow` with full model id `glm-5.3`, else `claude -p` with full model id `glm-5.3` (pool zai-coding)" glm
        && lib.all (runtime: !(lib.hasInfix "native (" (readPlanner poolResult runtime))) ["claude" "codex" "kiro"]
        && skillFails {
          ai.programs.delegate-routing.runtimes.claude.techniques = {
            Workflow.enable = false;
            "claude -p".modelArg = "";
          };
        }
        && skillFails {ai.programs.delegate-routing.runtimes.codex.techniques."codex exec".enable = false;}
    );
    # Orchestration marks render from family data: a renderer that hard-writes
    # the shipped marks or drops a consumer override fails here.
    "module-delegate-routing-${name}-orchestration" = mkTest "delegate-routing-${name}-orchestration" (
      let
        familyRow = text: family: lib.findFirst (lib.hasInfix "${family} (") "" (lib.splitString "\n" text);
        custom = skill {ai.programs.delegate-routing.families.anthropic.haiku.orchestration = "CUSTOM ORCHESTRATION";};
      in
        lib.hasInfix "default orchestrator" (familyRow claude "opus")
        && lib.hasInfix "default orchestrator" (familyRow claude "sol")
        && lib.hasInfix "reserved for hard work" (familyRow claude "astra")
        && lib.hasInfix "reserved for hard work" (familyRow claude "fable")
        && !(lib.hasInfix "orchestrator" (familyRow claude "haiku"))
        && lib.hasInfix "CUSTOM ORCHESTRATION" (familyRow custom "haiku")
    );
    "module-delegate-routing-${name}-kiro-workflows" = mkTest "delegate-routing-${name}-kiro-workflows" (let
      enabled = change {ai.kiro.cli.workflows.enable = true;};
      enabledSkill = readPlanner enabled "kiro";
      tweaksOn = result:
        result.config.ai.kiro.cli.tweaks.relativeFileCheckPaths
        && result.config.ai.kiro.cli.tweaks.stripVendorWorktreeSteering;
      tweaksOff = result:
        !result.config.ai.kiro.cli.tweaks.relativeFileCheckPaths
        && !result.config.ai.kiro.cli.tweaks.stripVendorWorktreeSteering;
      workflowChange = config: change (lib.recursiveUpdate {ai.kiro.cli.workflows.enable = true;} config);
      hidden = config: !(lib.hasInfix "`run_workflow`" (readPlanner (workflowChange config) "kiro"));
      effective = (import ../lib/select-families.nix {inherit lib;}).effectiveTechniques;
    in
      tweaksOff result
      && tweaksOn enabled
      && tweaksOff (workflowChange {ai.programs.delegate-routing.enable = false;})
      && tweaksOff (workflowChange {ai.kiro.cli.package = null;})
      && tweaksOff (workflowChange {
        ai.kiro.cli.enable = lib.mkForce false;
        ai.claude.enable = lib.mkForce false;
      })
      && tweaksOff (workflowChange {
        ai.programs.delegate-routing.runtimes.kiro.enable = false;
        ai.programs.delegate-routing.runtimes.claude.manualExternalDelegates = ["kimchi"];
      })
      && tweaksOn (workflowChange {ai.programs.delegate-routing.runtimes.kiro.enable = false;})
      && tweaksOn (evaluate (lib.recursiveUpdate manualScenario {
        ai.kiro.cli.workflows.enable = true;
        ai.programs.delegate-routing.runtimes.kiro.models = [{vendors = ["anthropic"];}];
      }))
      && tweaksOn (workflowChange {
        ai.programs.delegate-routing.runtimes.kiro.enable = false;
        ai.programs.delegate-routing.runtimes.claude = {
          extraRuntimes = ["kiro"];
          manualExternalDelegates = [];
        };
      })
      && tweaksOff (workflowChange {
        ai.kiro.cli.tweaks = {
          relativeFileCheckPaths = false;
          stripVendorWorktreeSteering = false;
        };
      })
      && !(lib.hasInfix "`run_workflow`" kiro)
      && !(lib.hasInfix "`run_workflow`" (readPlanner (change {ai.programs.delegate-routing.runtimes.kiro.techniques.run_workflow.enable = true;}) "kiro"))
      && lib.hasInfix "kiro: `run_workflow` with modelId the highest id matching `claude-opus-*`" enabledSkill
      && techniqueCells enabledSkill "run_workflow" == ["`run_workflow`" "workflow" "true" "true" "interactive+headless+acp"]
      && hidden {ai.kiro.cli.native.settings.chat.enableWorkflows = false;}
      && hidden {ai.programs.delegate-routing.runtimes.kiro.techniques.run_workflow.enable = false;}
      && !(lib.hasInfix "`run_workflow`" (readPlanner enabled "claude"))
      && (effective enabled.config).kiro.run_workflow.enable
      && !(effective result.config).kiro.run_workflow.enable);

    "module-delegate-routing-${name}-kiro-models" = mkTest "delegate-routing-${name}-kiro-models" (
      requiresSelection "kiro"
      && lib.hasInfix "opus (anthropic)" kiro
      && lib.hasInfix "haiku (anthropic)" kiro
      && !(lib.hasInfix "fable (anthropic)" kiro)
      && !(lib.hasInfix "sonnet (anthropic)" kiro)
      && !(lib.hasInfix "(openai)" kiro)
    );
    "module-delegate-routing-${name}-kimchi-models" = mkTest "delegate-routing-${name}-kimchi-models" (
      requiresSelection "kimchi"
      # Kimchi ships no default selection.
      && failsWith (evaluate (lib.updateManyAttrsByPath [
          {
            path = ["ai" "programs" "delegate-routing" "runtimes"];
            update = runtimes: builtins.removeAttrs runtimes ["kimchi"];
          }
        ]
        scenario)) "ai.programs.delegate-routing.runtimes.kimchi.models must select at least one"
      && result.config.ai.kimchi.skills ? delegate-routing
      && lib.hasInfix "flash (served)" kimchi
      && !(lib.hasInfix "(anthropic)" kimchi)
      && !(lib.hasInfix "(openai)" kimchi)
      && lib.hasInfix "### kimchi\n\n- flash (served)" claude
    );
    "module-delegate-routing-${name}-selectors" = mkTest "delegate-routing-${name}-selectors" (
      evaluationFails (selector {vendors = ["unknown"];})
      && evaluationFails (selector {families = ["unknown"];})
      && evaluationFails (change {
        ai = {
          programs.delegate-routing.families = lib.mapAttrs (_: lib.mapAttrs (_: _: {tier = "small";})) result.config.ai.programs.delegate-routing.families;
          programs.delegate-routing.runtimes.claude.models = [
            {families = ["opus"];}
            {tiers = ["frontier"];}
          ];
        };
      })
      && failsWith (selector {}) "ai.programs.delegate-routing.runtimes.claude.models contains an empty selector"
      && failsWith (selector {
        vendors = ["openai"];
        families = ["opus"];
      }) "ai.programs.delegate-routing.runtimes.claude.models must select"
      && passes (selector {
        vendors = ["anthropic"];
        tiers = ["strong" "small"];
      })
      && (let
        union = skill {
          ai.programs.delegate-routing.runtimes.claude = {
            extraRuntimes = [];
            manualExternalDelegates = [];
            models = [
              {families = ["haiku"];}
              {
                vendors = ["openai"];
                tiers = ["strong"];
              }
            ];
          };
        };
      in
        lib.hasInfix "haiku (anthropic)" union && lib.hasInfix "sol (openai)" union && !(lib.hasInfix "opus (anthropic)" union))
    );
    "module-delegate-routing-${name}-families" = mkTest "delegate-routing-${name}-families" (
      lib.hasInfix "CUSTOM OPUS TASK" familyOverride
      && lib.hasInfix "x (example)" addedFamily
      && lib.hasInfix "example-x-*" addedFamily
      && lib.hasInfix "CUSTOM FAMILY TASK" addedFamily
      && passes (change {
        ai.programs.delegate-routing.families.example.strong = {
          match = "example-*";
          tier = "small";
        };
      })
      && failsWith (change {
        ai.programs.delegate-routing.families.example.opus = {
          match = "example-opus-*";
          tier = "small";
        };
      }) "family names must be unique across vendors"
    );
    "module-delegate-routing-${name}-opencode-go-pool" = mkTest "delegate-routing-${name}-opencode-go-pool" (let
      expectedBindings = lib.genAttrs ["claude" "codex" "kiro"] (_: "go-budget");
      settings = {
        opencodeGo = {
          plan = "go-plus";
          pool = "go-budget";
        };
        pools.go-budget.window = goPoolWindow;
        runtimes = {
          claude.models = [{vendors = ["opencode-go"];}];
          codex.models = [{families = ["go-kimi-k3"];}];
          kiro.models = [
            {
              vendors = ["opencode-go"];
              families = ["go-kimi-k3"];
            }
          ];
        };
      };
      bound = change {ai.programs.delegate-routing = settings;};
      # Literal diagnostics reject a configuration that evaluates silently and
      # an assertion that checks only null, not an unregistered pool key.
      missingPoolMessage = "ai.programs.delegate-routing.opencodeGo.pool is null; the Go preset families would have no pool and rank on fit only. Set opencodeGo.pool to the registered pool key, e.g. \"opencode-go\".";
      unknownPoolMessage = "ai.programs.delegate-routing.opencodeGo.pool: unknown pool `missing-go-budget`; set it to a registered pool key, e.g. \"opencode-go\", declared under ai.programs.delegate-routing.pools.";
      unboundSettings = settings // {opencodeGo = {plan = "go-plus";};};
      unbound = change {ai.programs.delegate-routing = unboundSettings;};
      handBound = change {
        ai.programs.delegate-routing =
          unboundSettings
          // {
            families.opencode-go = lib.mapAttrs (_: _: {pools = expectedBindings;}) bound.config.ai.programs.delegate-routing.families.opencode-go;
          };
      };
      unknownPool = change {
        ai.programs.delegate-routing =
          settings
          // {
            opencodeGo = {
              plan = "go-plus";
              pool = "missing-go-budget";
            };
          };
      };
      # No selected Go runtime can mask an invalid module-level pool binding.
      unselected = change {ai.programs.delegate-routing.opencodeGo.plan = "go-plus";};
      hasFailure = evaluation: message:
        lib.any (item: !item.assertion && item.message == message) evaluation.config.assertions;
      text = readPlanner bound "claude";
      lines = lib.splitString "\n" text;
      overridden = change {
        ai.programs.delegate-routing =
          settings
          // {
            families.opencode-go.go-kimi-k3.pools.claude = null;
          };
      };
    in
      passes bound
      && hasFailure unbound missingPoolMessage
      && hasFailure handBound missingPoolMessage
      && hasFailure unselected missingPoolMessage
      && hasFailure unknownPool unknownPoolMessage
      # A null plan keeps fit-only Go presets supported without a pool binding.
      && passes (change {ai.programs.delegate-routing = settings // {opencodeGo.plan = null;};})
      && lib.all (family: family.pools == expectedBindings)
      (builtins.attrValues bound.config.ai.programs.delegate-routing.families.opencode-go)
      && lib.hasInfix "## Pools" text
      && lib.hasInfix "| Pool " text
      && lib.hasInfix "go-plus: unlimited" text
      # The bound pool follows each reach in the Launch cell, and follows the
      # launch in a manual-only list item, ahead of the plan's pool hint.
      && builtins.match ".*claude: [^|]* \\(pool go-budget\\); via codex: [^|]* \\(pool go-budget\\) \\|.*" (lib.findFirst (lib.hasPrefix "| go-kimi-k3 (opencode-go)") "" lines) != null
      && lib.any (line: builtins.match "- go-kimi-k3 \\(opencode-go\\) `kimi-k3`: .* \\(pool go-budget\\); go-plus: .*" line != null) (lib.splitString "\n" (lib.replaceStrings ["\n  "] [" "] text))
      && passes overridden
      && overridden.config.ai.programs.delegate-routing.families.opencode-go.go-kimi-k3.pools.claude == null
      && poolFailsWith (change {ai.programs.delegate-routing = settings // {pools = {};};})
      "unknown pool `go-budget`"
      && lib.all (family: family.pools == expectedBindings)
      (builtins.attrValues
        (change {
          ai.programs.delegate-routing =
            settings
            // {
              opencodeGo = {
                plan = null;
                pool = "go-budget";
              };
            };
        }).config.ai.programs.delegate-routing.families.opencode-go));
    "module-delegate-routing-${name}-opencode-go" = mkTest "delegate-routing-${name}-opencode-go" (let
      goSelected = plan:
        change {
          ai.programs.delegate-routing = {
            opencodeGo = {
              inherit plan;
              pool =
                if plan == null
                then null
                else "go-budget";
            };
            pools = lib.optionalAttrs (plan != null) {go-budget.window = goPoolWindow;};
            runtimes.claude = {
              extraRuntimes = [];
              manualExternalDelegates = [];
              models = [{vendors = ["opencode-go"];}];
            };
          };
        };
      kimi = {
        match = "kimi-k3*";
        tier = "strong";
      };
      overlapping = families: models:
        change {
          ai.programs.delegate-routing = {
            inherit families;
            runtimes.claude.models = [{vendors = ["opencode-go"];}] ++ models;
          };
        };
      note = "The opencode-go families come from per-model research: their tiers and effort guidance are provisional, not measured on this workload.";
      planned = readPlanner (goSelected "go-plus") "claude";
      unplanned = readPlanner (goSelected null) "claude";
    in
      # Presets ship but render only when selected; the default skill has no
      # provisional note; the Pool column remains even without pool guidance.
      !(lib.hasInfix "(opencode-go)" claude)
      && lib.hasInfix "| Pool " claude
      && !(hasProse note claude)
      && lib.hasInfix "go-kimi-k3 (opencode-go)" planned
      && hasProse note planned
      && !(hasProse note (readPlanner (change {
        ai.programs.delegate-routing = {
          runtimes.claude.models = [{vendors = ["opencode-go"];}];
          skill.entries."Family tables".enable = false;
        };
      }) "claude"))
      && lib.hasInfix "| Pool " planned
      && lib.hasInfix "go-plus: $60 of list-price use empties the monthly pool" planned
      && lib.hasInfix "go-plus: unlimited" planned
      && lib.hasInfix "go-kimi-k3 (opencode-go)" unplanned
      && lib.hasInfix "| Pool " unplanned
      && lib.all (line: let
        cells = lib.splitString "|" line;
      in
        lib.trim (builtins.elemAt cells (builtins.length cells - 3)) == "")
      (builtins.filter (line: lib.hasPrefix "| go-" line) (lib.splitString "\n" unplanned))
      && passes (goSelected "go-plus")
      # A manual-only target's Go families carry the same pool hint on their
      # own list item; the formatter wraps list items onto indented lines.
      && lib.any (line: lib.hasPrefix "- go-kimi-k3 (opencode-go) `kimi-k3`: " line && lib.hasSuffix "; go-plus: $60 of list-price use empties the monthly pool" line) (lib.splitString "\n" (lib.replaceStrings ["\n  "] [" "] (skill {
        ai.programs.delegate-routing = {
          opencodeGo = {
            plan = "go-plus";
            pool = "go-budget";
          };
          pools.go-budget.window = goPoolWindow;
          runtimes.kimchi.models = [{vendors = ["opencode-go"];}];
        };
      })))
      # A selected preset and another family, of any vendor, matching the
      # same Go catalog model on one runtime fail; on different runtimes, or
      # with no preset selected, they pass.
      && lib.all (failsWith (overlapping {example.kimi = kimi;} [{families = ["kimi"];}])) ["kimi-k3 (" "example.kimi" "opencode-go.go-kimi-k3"]
      && failsWith (overlapping {opencode-go.mine = kimi;} []) "opencode-go.mine"
      && passes (change {
        ai.programs.delegate-routing = {
          families.example.kimi = kimi;
          runtimes = {
            claude.models = [{families = ["kimi"];}];
            codex.models = [{vendors = ["opencode-go"];}];
          };
        };
      })
      && passes (change {
        ai.programs.delegate-routing = {
          families = {
            example.kimi = kimi;
            other.kimi-exact = kimi // {match = "kimi-k3";};
          };
          runtimes.claude.models = [{families = ["kimi" "kimi-exact"];}];
        };
      }));
    "module-delegate-routing-${name}-technique-assertions" = mkTest "delegate-routing-${name}-technique-assertions" (
      failsWith (invalidNode {
        kind = "subagent";
        pinsModel = true;
      }) "techniques.Invalid: pinsModel and pinsEffort"
      && failsWith (invalidNode {
        kind = "workflow";
        pinsEffort = true;
      }) "techniques.Invalid: pinsModel and pinsEffort"
      && failsWith (invalidNode {
        kind = "usage";
        pinsModel = false;
      }) "techniques.Invalid: pinsModel and pinsEffort"
      && failsWith (invalidNode {
        kind = "introspect";
        pinsEffort = false;
      }) "techniques.Invalid: pinsModel and pinsEffort"
      && failsWith (invalidNode {
        kind = "external";
        modelArg = "full model id";
        pinsModel = true;
        pinsEffort = true;
      }) "techniques.Invalid.command"
      && passes (invalidNode {
        command = "external-command";
        kind = "external";
        modelArg = "full model id";
        pinsEffort = true;
        pinsModel = true;
      })
    );
    "module-delegate-routing-${name}-techniques" = mkTest "delegate-routing-${name}-techniques" (
      techniqueRow disabledNode "Agent"
      == ""
      && lib.hasInfix "`Workflow`" disabledNode
      && lib.hasInfix "CUSTOM CODEX COMMAND" modifiedNode
      && !(lib.hasInfix "| workflow" codex)
      && lib.hasInfix "headless+acp" kiroInvoke
      && lib.hasInfix "/bin/claude-usage`" claude
      && lib.hasInfix "/bin/codex-usage`" codex
      && !(lib.hasInfix "(usage)" kiro)
      && !(lib.hasInfix "`spawn_agent`" claude)
      && !(lib.hasInfix "`invoke_sub_agent`" claude)
      && lib.hasInfix "kiro-cli chat --no-interactive --model <id> --effort <effort>" claude
      && lib.hasInfix "always pass `thinking` explicitly" (techniqueRow kimchi "Agent")
      && techniqueCells kimchi "Agent" == ["`Agent`" "subagent" "true" "true" "acp+headless+interactive"]
      # Fails if Claude's Agent row loses its effort or alias model pin.
      && techniqueCells claude "Agent" == ["`Agent`" "subagent" "true" "true" "interactive+headless"]
      && lib.hasInfix "**models (introspect):** `kimchi --list-models`" kimchi
      && !(lib.hasInfix "(usage)" kimchi)
      && lib.hasInfix "### kimchi techniques" claude
      && lib.hasInfix "kimchi -p --mode json --no-session --model <id> --thinking <level>" claude
      && !(lib.hasInfix "`/workflow`" claude)
      && hasProse "comparing version numbers segment by segment (6.1 > 6 > 5.6)" claude
      && hasProse "Use a technique only if it appears in your tool list" claude
      && hasProse "an agent cannot reliably tell which mode it is in, but it can see its tools" claude
      && techniqueCells kiro "orchestrate_subagent" == ["`orchestrate_subagent`" "subagent" "false" "false" "interactive+acp"]
      && hasProse "some ACP clients enable it in place of invoke_sub_agent" kiro
      && lib.hasInfix "| Runs own subagents" claude
      && ownSubagents kiro "orchestrate_subagent" == "unknown"
      && ownSubagents ownSubagentsOverride "codex exec" == "CUSTOM OWN SUBAGENTS"
    );
    "module-delegate-routing-${name}-external-enable" = mkTest "delegate-routing-${name}-external-enable" (
      failsWith invalid "ai.programs.delegate-routing.runtimes.claude.extraRuntimes includes `kiro`, but ai.kiro.enable is false. Enable it with ai.kiro.cli.enable = true."
      && failsWith manualMissingModels "ai.programs.delegate-routing.runtimes.kiro.models must select at least one"
      && passes manualManaged
      && lib.hasInfix "## manual-only external delegates\n\n### kiro\n\n-" (readPlanner manualManaged "claude")
      && lib.hasInfix "### kiro techniques" (readPlanner manualManaged "claude")
      && passes manualOverlap
      && readPlanner manualOverlap "claude" == readPlanner manualManaged "claude"
      && failsWith extraProgramDisabledKiroMissingModels "ai.programs.delegate-routing.runtimes.kiro.models must select at least one"
      && passes extraProgramDisabledKiro
    );
    "module-delegate-routing-${name}-manual-external-enable" = mkTest "delegate-routing-${name}-manual-external-enable" (
      failsWith manualRuntimeDisabled "ai.programs.delegate-routing.runtimes.claude.manualExternalDelegates includes `kiro`, but ai.kiro.enable is false. Enable it with ai.kiro.cli.enable = true."
      && passes manualManaged
    );
    "module-delegate-routing-${name}-options" = mkTest "delegate-routing-${name}-options" (
      let
        portable = optionTree result ["ai" "programs" "delegate-routing"];
        perRuntime = portable.runtimes.claude;
      in
        portable ? enable
        && portable ? families
        && portable ? reminder
        && perRuntime ? reminder
        && portable ? routing
        && portable ? workflows
        && !(portable ? extraRuntimes)
        && !(portable ? manualExternalDelegates)
        && !(portable ? models)
        && !(portable ? techniques)
        && perRuntime ? extraRuntimes
        && perRuntime ? manualExternalDelegates
        && perRuntime ? routing
        && perRuntime ? workflows
        && perRuntime ? models
        && perRuntime ? techniques
        && portable.runtimes ? kimchi
        && !(portable.runtimes ? copilot)
    );
    "module-delegate-routing-${name}-overrides" = mkTest "delegate-routing-${name}-overrides" (
      !(disabled.config.ai.codex.skills ? delegate-routing)
      && !(disabled.config.ai.codex.rules ? delegate-routing-router)
      && disabled.config.ai.claude.skills ? delegate-routing
      && !(result.config.ai.skills ? delegate-routing)
      && !(result.config.ai.rules ? delegate-routing-router)
    );
    "module-delegate-routing-${name}-reminder" = mkTest "delegate-routing-${name}-reminder" (
      result.config.ai.programs.delegate-routing.reminder.enable
      && result.config.ai.programs.delegate-routing.reminder.text == reminderBaseText
      && lib.all (runtime: builtins.length (reminderCommands result runtime) == reminderCases.${runtime}) runtimes
    );
    "module-delegate-routing-${name}-reminder-disabled" = mkTest "delegate-routing-${name}-reminder-disabled" (
      lib.all (runtime: let
        absent = evaluation: !(hasReminder evaluation runtime);
        override = reminderOverride runtime;
      in
        absent reminderOff
        && absent (change {ai.programs.delegate-routing.runtimes.${runtime}.reminder.enable = false;})
        && absent (change {ai.programs.delegate-routing.runtimes.${runtime}.enable = false;})
        && absent (change (setEnable runtime (lib.mkForce false)))
        && absent (change {ai.programs.delegate-routing.enable = false;})
        && hasReminder override runtime == (reminderCases.${runtime} == 1)
        && lib.all (other: !(hasReminder override other)) (lib.remove runtime runtimes))
      runtimes
      && failsWith (change {
        ai.programs.delegate-routing = {
          reminder = {
            enable = false;
            text = "";
          };
          runtimes.claude.reminder.enable = true;
        };
      }) "ai.programs.delegate-routing.reminder.text"
    );
    "module-delegate-routing-${name}-reminder-hooks-dir-conflict" = let
      withHooksDir = change {ai.kiro.hooksDir = ../../kiro-cli/checks/fixtures/kiro-hooks-dir;};
      withoutReminder = change {
        ai.kiro.hooksDir = ../../kiro-cli/checks/fixtures/kiro-hooks-dir;
        ai.programs.delegate-routing.runtimes.kiro.reminder.enable = false;
      };
    in
      mkTest "delegate-routing-${name}-reminder-hooks-dir-conflict" (
        failsWith withHooksDir "Set runtimes.kiro.reminder.enable = false or move those hooks out of hooksDir."
        && passes withoutReminder
      );
    "module-delegate-routing-${name}-reminder-payload" = let
      samples = lib.concatMap (runtime:
        map (sample: {
          command = builtins.head (reminderCommands sample.evaluation runtime);
          expected =
            if runtime == "kiro"
            then sample.text
            else
              builtins.toJSON {
                hookSpecificOutput = {
                  additionalContext = sample.text;
                  hookEventName = "UserPromptSubmit";
                };
              };
        }) (map (pair: {
            evaluation = builtins.head pair;
            text = builtins.elemAt pair 1;
          }) [
            # Reject missing lines, portable-only gating and ignored runtime text.
            [result "${reminderBaseText}\n${orchestratorLine}"]
            [orchestratorOff reminderBaseText]
            [(orchestratorRuntimeOff runtime) reminderBaseText]
            [
              (orchestratorRuntimeOff (
                if runtime == "claude"
                then "codex"
                else "claude"
              ))
              "${reminderBaseText}\n${orchestratorLine}"
            ]
            [(orchestratorRuntimeText runtime) "${reminderBaseText}\nI want runtime guidance kept in one line."]
            [reminderCustom "${reminderCustomText}\n${orchestratorLine}"]
            [reminderSource "${builtins.readFile reminderSourcePath}\n${orchestratorLine}"]
          ]))
      hookRuntimes;
    in
      pkgs.runCommand "delegate-routing-${name}-reminder-payload" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        ${lib.getExe pkgs.python3} - ${pkgs.writeText "reminder-samples.json" (builtins.toJSON samples)} <<'PYTHON'
        import json
        import subprocess
        import sys
        with open(sys.argv[1]) as source:
            for sample in json.load(source):
                actual = subprocess.check_output([sample["command"]], input=b'{}', timeout=5).decode()
                if sample["expected"].startswith('{"hookSpecificOutput"'):
                    json.loads(actual)
                assert actual == sample["expected"], (sample, actual)
        PYTHON
        touch "$out"
      '';
    "module-delegate-routing-${name}-reminder-warnings" = let
      unsupportedWarning = evaluation: lib.any (lib.hasInfix "runtimes.kimchi.reminder.enable is true, but this backend cannot deliver") evaluation.config.warnings;
    in
      mkTest "delegate-routing-${name}-reminder-warnings" (
        lib.assertMsg (!reminderWarning result.config.warnings) (lib.concatStringsSep "\n" result.config.warnings)
        && reminderWarning reminderWithIgnoredPrompt.config.warnings
        && !(unsupportedWarning result)
        && unsupportedWarning (reminderOverride "kimchi") == (name == "hm")
        && !(unsupportedWarning (change {
          ai.programs.delegate-routing.runtimes.kimchi = {
            enable = false;
            reminder.enable = true;
          };
        }))
      );
    "module-delegate-routing-${name}-routing-defaults" = mkTest "delegate-routing-${name}-routing-defaults" (
      # Fails if "Orchestrator session" ships off or any other entry default moves.
      builtins.attrNames (lib.filterAttrs (_: entry: entry.enable) routingDefaults)
      == ["Choose execution" "Follow the user's request" "Load delegate-routing" "Orchestrator session" "Pool drain" "Size the work" "Tune these rules" "Validate the result"]
      && routingDefaults."Orchestrator session".enable
      && routingDefaults."Orchestrator session".always
      && routingDefaults."Load delegate-routing".always
      && !routingDefaults."Pool drain".always
      && !routingDefaults."Validate the result".always
      && ordered claude ["Follow the user's request" "Size the work" "Choose execution"]
      && lib.hasInfix "## Routing" claude
      && hasLoadInstruction stub
      && !(lib.hasInfix "### Pool drain" stub)
      && lib.hasInfix "### Orchestrator session" stub
      && !(lib.hasInfix "### Validate the result" stub)
      && !(lib.hasInfix "### Load delegate-routing" claude)
      && !(lib.hasInfix "### Orchestrator session" claude)
      && lib.hasInfix "### Pool drain" claude
      && lib.hasInfix "### Validate the result" claude
      && !(lib.hasInfix "### Size the work" stub)
      && lib.hasInfix "### Tune these rules" claude
      && !(lib.hasInfix "### Tune these rules" stub)
      && !(alwaysDisabled.config.ai.claude.rules ? delegate-routing-router)
      && !(alwaysDisabled.config.ai.codex.rules ? delegate-routing-router)
      && lib.hasInfix "## Routing" (readPlanner alwaysDisabled "claude")
      # Shared AGENTS.md targets require byte-identical runtime rule contributions.
      && lib.all (runtime: result.config.ai.${runtime}.rules.delegate-routing-router.text == stub) runtimes
    );
    "module-delegate-routing-${name}-routing-consumer" = mkTest "delegate-routing-${name}-routing-consumer" (
      !(lib.hasInfix "### Size the work" (readPlanner routingDisabled "claude"))
      && lib.hasInfix "### Follow the user's request" (readPlanner routingDisabled "claude")
      && lib.hasInfix "### Choose execution" (readPlanner routingDisabled "claude")
      && lib.hasInfix "CUSTOM REQUEST GUIDANCE" (readPlanner routingReplaced "claude")
      && lib.hasInfix "### Size the work" (readPlanner routingReplaced "claude")
      && lib.hasInfix "### Choose execution" (readPlanner routingReplaced "claude")
      && ordered (readPlanner routingInserted "claude") ["Follow the user's request" "Size the work" "Consumer guidance" "Choose execution"]
      && lib.hasInfix "CUSTOM INSERTED GUIDANCE" (readPlanner routingInserted "claude")
      # Fails if a consumer text override stops rendering once the entry ships on.
      && catalogOverridden.config.ai.programs.delegate-routing.routing."Orchestrator session".enable
      && lib.hasInfix "### Orchestrator session" (ruleText catalogOverridden)
      && lib.hasInfix "CUSTOM ORCHESTRATOR GUIDANCE" (ruleText catalogOverridden)
      && !(lib.hasInfix "Keep this session" (ruleText catalogOverridden))
      # Fails if a plain consumer enable = false cannot turn the entry off.
      && !catalogDisabled.config.ai.programs.delegate-routing.routing."Orchestrator session".enable
      && !(lib.hasInfix "### Orchestrator session" (ruleText catalogDisabled))
      && !(lib.hasInfix "Keep this session" (ruleText catalogDisabled))
    );
    "module-delegate-routing-${name}-routing-runtime" = mkTest "delegate-routing-${name}-routing-runtime" (
      lib.hasInfix "CLAUDE GUIDANCE" (readPlanner runtimeRouting "claude")
      && !(lib.hasInfix "PORTABLE GUIDANCE" (readPlanner runtimeRouting "claude"))
      && !(lib.hasInfix "### Portable guidance" (ruleText runtimeRouting))
      && lib.hasInfix "PORTABLE GUIDANCE" runtimeRouting.config.ai.codex.rules.delegate-routing-router.text
      && !(lib.hasInfix "### Size the work" (readPlanner runtimeRouting "claude"))
      && lib.hasInfix "### Size the work" (readPlanner runtimeRouting "codex")
      # Fails if a runtime record cannot turn the shipped entry off for itself.
      && !(lib.hasInfix "### Orchestrator session" (ruleText runtimeCatalogDisabled))
      && lib.hasInfix "### Orchestrator session" runtimeCatalogDisabled.config.ai.codex.rules.delegate-routing-router.text
    );
    "module-delegate-routing-${name}-workflows" = mkTest "delegate-routing-${name}-workflows" (
      result.config.ai.programs.delegate-routing.workflows.${workflowName}.enable
      && lib.hasInfix "## Common workflows" claude
      && lib.hasInfix "### ${workflowName}" claude
      && lib.hasInfix "### ${workflowName}" codex
      && lib.hasInfix workflowHeader claude
      && lib.hasInfix "1. **Rubric:**" claude
      && lib.hasInfix "7. **Loop:**" claude
      # Fails if units lose their definition, cadence or vendor separation,
      # fixes re-review the whole branch or retain its base, or mid-build
      # units remain subject to the opening three-check rule, or the
      # branch-level review loses its ready/earlier sizing.
      && hasProse "A unit is a bounded change with one reader and one verification" claude
      && hasProse "Each unit is reviewed by one check, from a vendor other than the writer's, before the next unit starts." claude
      && hasProse "the fix's diff plus what it touches, one check, never the whole branch again." claude
      && hasProse "for a fix round, HEAD before the fix starts" claude
      && hasProse "a unit of a branch still being built, the branch-level review of a branch not yet going ready, and a fix after any review each get one reviewer" claude
      && hasProse "all three checks when the PR is going ready, one check in any earlier state." claude
      && lib.hasInfix workflowHeader (readPlanner runtimeWorkflowStep "claude")
      && lib.hasInfix "CLAUDE WORKFLOW STEP" (readPlanner runtimeWorkflowStep "claude")
      && lib.hasInfix "7. **Loop:**" (readPlanner runtimeWorkflowStep "claude")
      && lib.hasInfix "CLAUDE CATALOG INTRO" (readPlanner runtimeCatalogHeader "claude")
      && !(lib.hasInfix workflowHeader (readPlanner runtimeCatalogHeader "claude"))
      && lib.hasInfix "1. **Rubric:**" (readPlanner runtimeCatalogHeader "claude")
      && lib.hasInfix "7. **Loop:**" (readPlanner runtimeCatalogHeader "claude")
      && !(lib.hasInfix "CLAUDE CATALOG INTRO" (readPlanner runtimeCatalogHeader "codex"))
      && !(lib.hasInfix "### ${workflowName}" (readPlanner runtimeWorkflowDisabled "claude"))
      && lib.hasInfix "### ${workflowName}" (readPlanner runtimeWorkflowDisabled "codex")
      && lib.hasInfix "CUSTOM WORKFLOW STEP" (readPlanner workflowInserted "claude")
      && (let
        text = readPlanner workflowInserted "claude";
        rubric = builtins.head (lib.splitString "CUSTOM WORKFLOW STEP" text);
        remainder = builtins.elemAt (lib.splitString "CUSTOM WORKFLOW STEP" text) 1;
      in
        lib.hasInfix "Rubric" rubric && lib.hasInfix "Review" remainder)
    );
    "module-delegate-routing-${name}-workflow-runtime" = mkTest "delegate-routing-${name}-workflow-runtime" (
      let
        text = readPlanner runtimeWorkflow "claude";
        codexRule = runtimeWorkflow.config.ai.codex.rules.delegate-routing-router.text;
      in
        lib.hasInfix "CLAUDE WORKFLOW INTRO" text
        && !(lib.hasInfix "PORTABLE WORKFLOW INTRO" text)
        && lib.hasInfix "CLAUDE FIRST STEP" text
        && !(lib.hasInfix "PORTABLE FIRST STEP" text)
        && lib.hasInfix "CLAUDE MIDDLE STEP" text
        && lib.hasInfix "PORTABLE LAST STEP" text
        && lib.hasInfix "1. **First:**" text
        && lib.hasInfix "2. **Middle:**" text
        && lib.hasInfix "3. **Last:**" text
        && lib.hasInfix "PORTABLE WORKFLOW INTRO" codexRule
        && lib.hasInfix "PORTABLE FIRST STEP" codexRule
        && !(lib.hasInfix "CLAUDE MIDDLE STEP" codexRule)
    );
    "module-delegate-routing-${name}-skill-entry-override" = mkTest "delegate-routing-${name}-skill-entry-override" (
      let
        overridden = change {
          ai.programs.delegate-routing = {
            runtimes.claude.skill.phrases."Model pattern".text = "newest `{match}`";
            skill.entries."Technique availability".text = "CUSTOM TECHNIQUE AVAILABILITY";
          };
        };
        text = readPlanner overridden "claude";
        beforeCustom = builtins.head (lib.splitString "CUSTOM TECHNIQUE AVAILABILITY" text);
        afterCustom = builtins.elemAt (lib.splitString "CUSTOM TECHNIQUE AVAILABILITY" text) 1;
      in
        # Fails if the renderer keeps the literal and ignores the entry (old
        # text stays, custom text absent), if an override drops the shipped
        # `after` edges (custom text leaves its position between the family
        # tables and the technique tables), or if a runtime phrase leaks to
        # other runtimes (codex loses "the highest id matching").
        lib.hasInfix "CUSTOM TECHNIQUE AVAILABILITY" text
        && !(lib.hasInfix "Use a technique only if it appears" text)
        && lib.hasInfix "### small" beforeCustom
        && lib.hasInfix "### claude techniques" afterCustom
        && !(lib.hasInfix "### small" afterCustom)
        && lib.hasInfix "newest `claude-opus-*`" text
        && lib.hasInfix "the highest id matching" (readPlanner overridden "codex")
        && !(lib.hasInfix "newest `" (readPlanner overridden "codex"))
    );
    "module-delegate-routing-${name}-skill-entry-disable" = mkTest "delegate-routing-${name}-skill-entry-disable" (
      let
        disabledEntries = change {
          ai.programs.delegate-routing.skill = {
            columns.families.Orchestration.enable = false;
            entries."Delegate sizing".enable = false;
          };
        };
        text = readPlanner disabledEntries "claude";
        header = lib.findFirst (lib.hasPrefix "| Family") "" (lib.splitString "\n" text);
        headerCells = lib.filter (cell: cell != "") (map lib.trim (lib.splitString "|" header));
        positionOf = needle: builtins.stringLength (builtins.head (lib.splitString needle text));
      in
        # Fails if enable is ignored (sizing paragraph or column stays), if
        # disabling an entry loses the order of later entries (workflows, tiers and
        # technique tables change order), or if a disabled column keeps its
        # cells (the opus row still says "default orchestrator").
        !(lib.hasInfix "## delegate sizing" text)
        && !(lib.hasInfix "Each row is a family" text)
        && positionOf "## Common workflows" < positionOf "### frontier"
        && positionOf "### frontier" < positionOf "### claude techniques"
        && headerCells == ["Family" "Use for" "Avoid for" "Effort (delegate)" "Pool" "Launch"]
        && !(lib.hasInfix "default orchestrator" text)
        # An enabled column the renderer has no cell for is refused, not
        # rendered as an empty column.
        && skillFails {ai.programs.delegate-routing.skill.columns.families.Unknown.text = "Unknown";}
    );
    "module-delegate-routing-${name}-content-validation" = mkTest "delegate-routing-${name}-content-validation" (
      !(builtins.tryEval (builtins.deepSeq
        (change {
          ai.programs.delegate-routing.routing.Empty = {
            enable = true;
            text = "";
          };
        }).config.ai.programs.delegate-routing.routing.Empty.text
        true)).success
      && !(builtins.tryEval (builtins.deepSeq contentConflict.config.ai.programs.delegate-routing.routing.Conflict.text true)).success
      && identicalContent.config.ai.programs.delegate-routing.routing.Conflict.text == "IDENTICAL CONTENT"
      && !(builtins.tryEval (builtins.deepSeq
        (change {
          ai.programs.delegate-routing.workflows.Empty = {
            always = true;
            enable = true;
            text = "";
          };
        }).config.ai.claude.rules.delegate-routing-router.text
        true)).success
      && !(builtins.tryEval (builtins.deepSeq
        (change {
          ai.programs.delegate-routing.workflows.Consumer.steps.Empty = {
            enable = true;
            text = "";
          };
        }).config.ai.programs.delegate-routing.workflows.Consumer.steps.Empty.text
        true)).success
      && !(builtins.tryEval (builtins.deepSeq
        (change {
          ai.programs.delegate-routing.workflows.Consumer.steps.X = {
            always = true;
            text = "X";
          };
        }).config.ai.programs.delegate-routing.workflows
        true)).success
      && !(builtins.tryEval (builtins.deepSeq (ruleText cyclicRouting) true)).success
      && !(builtins.tryEval (builtins.deepSeq (ruleText cyclicWorkflow) true)).success
      && lib.all (edge: !(builtins.tryEval (builtins.deepSeq (selfCycle edge) true)).success) ["after" "before"]
      && lib.all (edge: !(builtins.tryEval (builtins.deepSeq (selfCycleStep edge) true)).success) ["after" "before"]
      && passes routingInserted
      && lib.hasInfix "DISABLED ANCHOR GUIDANCE" (ruleText disabledAnchor)
    );
  };
in {
  checks =
    {
      # The public builder is overridable from the shipped inputs. Fails if
      # mkSkill returns no `.override`, if `prev` lacks the shipped `skill`, or
      # if the override does not reach the render; the second half fails if
      # overriding leaks into the un-overridden skill.
      module-delegate-routing-builder-override = let
        content = (evalHm scenario).config.ai.internal.roots.delegate-routing-content;
        base = content.passthru.mkSkill {runtime = "claude";};
        overridden = base.override (prev: {
          skill = lib.recursiveUpdate prev.skill {phrases."Launch fallback".text = ", or ";};
        });
      in
        mkTest "delegate-routing-builder-override" (
          lib.hasInfix "`Workflow` with full model id the highest id matching `claude-opus-*`, or `claude -p`" (builtins.readFile "${overridden}/PLANNER.md")
          && !(lib.hasInfix ", else `claude -p`" (builtins.readFile "${overridden}/PLANNER.md"))
          && lib.hasInfix "`Workflow` with full model id the highest id matching `claude-opus-*`, else `claude -p`" (builtins.readFile "${base}/PLANNER.md")
          && base.text == content.passthru.skills.claude.text
          && lib.hasInfix "--role planner" base.text
          && !(lib.hasInfix "| Family" base.text)
        );
      # tryEval cannot expose the diagnostic; evaluate the resolver in a subprocess.
      module-delegate-routing-cycle-message = let
        probe = pkgs.writeText "delegate-routing-cycle.nix" ''
          { selfCycle ? false }:
          let
            lib = import ${pkgs.path}/lib;
            entries = import ${../lib/resolve-entries.nix} { inherit lib; };
            entry = after: { inherit after; before = []; enable = true; };
          in entries.sort "delegate-routing.routing" (
            if selfCycle then { Self = entry ["Self"]; }
            else { Alpha = entry ["Beta"]; Beta = entry ["Alpha"]; }
          )
        '';
      in
        pkgs.runCommandLocal "module-test-delegate-routing-cycle-message" {
          nativeBuildInputs = [pkgs.nix];
        } ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          export NIX_STATE_DIR="$TMPDIR/nix-state"
          export USER="''${USER:-nixbld}"
          mkdir -p "$NIX_STATE_DIR/profiles/per-user/$USER"
          if nix-instantiate --eval --strict ${probe} --arg selfCycle false >actual.stdout 2>actual.stderr; then
            echo "FAIL: routing cycle unexpectedly succeeded" >&2
            exit 1
          fi
          grep -F 'delegate-routing.routing: ordering cycle involving Alpha, Beta' actual.stderr
          if nix-instantiate --eval --strict ${probe} --arg selfCycle true >actual.stdout 2>actual.stderr; then
            echo "FAIL: routing self-cycle unexpectedly succeeded" >&2
            exit 1
          fi
          grep -F 'delegate-routing.routing: ordering cycle involving Self' actual.stderr
          touch "$out"
        '';
    }
    // checkBackend {
      name = "devenv";
      evaluate = evalDevenv;
    }
    // checkBackend {
      name = "hm";
      evaluate = evalHm;
    };
}
