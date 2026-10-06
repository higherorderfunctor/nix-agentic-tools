# cspell:ignore Prio sublist
# Exercise the generated files as delivered through both consumer backends.
{
  harness,
  lib,
  pkgs,
  ...
}: let
  inherit (harness) evalDevenv evalHm mkTest;
  runtimes = ["claude" "codex" "kimchi" "kiro"];
  scenario.ai = {
    claude.enable = true;
    codex.enable = true;
    kimchi = {
      enable = true;
      # Home Manager requires an account region.
      native.settings.region = "us";
    };
    kiro.enable = true;
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
  hasLoadInstruction = text: lib.hasInfix "load the delegate-routing skill" (lib.replaceStrings ["\n" "`"] [" " ""] text);
  readSkill = result: runtime: builtins.readFile "${result.config.ai.${runtime}.skills.delegate-routing}/SKILL.md";
  optionTree = result: path: lib.getAttrFromPath path result.options;
  checkBackend = {
    name,
    evaluate,
  }: let
    result = evaluate scenario;
    claude = readSkill result "claude";
    codex = readSkill result "codex";
    kimchi = readSkill result "kimchi";
    kiro = readSkill result "kiro";
    stub = result.config.ai.claude.extraSystemPrompt.delegate-routing.text;
    change = config: evaluate (lib.recursiveUpdate scenario config);
    skill = config: readSkill (change config) "claude";
    passes = evaluation: lib.all (item: item.assertion) evaluation.config.assertions;
    failsWith = evaluation: option: lib.any (item: !item.assertion && lib.hasInfix option item.message) evaluation.config.assertions;
    evaluationFails = evaluation: !(builtins.tryEval (builtins.deepSeq evaluation.config.ai.programs.delegate-routing.runtimes.claude true)).success;
    hasProse = needle: text: lib.hasInfix needle (lib.replaceStrings ["\n"] [" "] text);
    native = change {ai.programs.delegate-routing.runtimes.claude.extraRuntimes = [];};
    nativeClaude = readSkill native "claude";
    disabled = evaluate {
      ai.programs.delegate-routing.enable = true;
      ai.programs.delegate-routing.runtimes.codex.enable = false;
    };
    # Kimchi has no Home Manager hook file, so only devenv delivers its reminder.
    hookRuntimes =
      if name == "hm"
      then lib.remove "kimchi" runtimes
      else runtimes;
    reminderCommands = evaluation: runtime:
      if runtime == "kiro"
      then lib.optional (evaluation.config.ai.kiro.hooks ? delegate-routing-reminder) evaluation.config.ai.kiro.hooks.delegate-routing-reminder.action.command
      else lib.concatMap (block: map (handler: handler.command) block.hooks) (evaluation.config.ai.${runtime}.hooks.UserPromptSubmit or []);
    hasReminder = evaluation: runtime: lib.any (lib.hasInfix "delegate-routing-reminder") (reminderCommands evaluation runtime);
    reminderOff = change {ai.programs.delegate-routing.reminder.enable = false;};
    reminderOnlyClaude = change {
      ai.programs.delegate-routing = {
        reminder.enable = false;
        runtimes.claude.reminder.enable = true;
      };
    };
    reminderOnlyClaudeEmpty = change {
      ai.programs.delegate-routing = {
        reminder = {
          enable = false;
          text = "";
        };
        runtimes.claude.reminder.enable = true;
      };
    };
    reminderOffForCodex = change {ai.programs.delegate-routing.runtimes.codex.reminder.enable = false;};
    reminderCustom = change {ai.programs.delegate-routing.reminder.text = "CUSTOM REMINDER";};
    manualScenario.ai = {
      claude.enable = true;
      kiro.enable = true;
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
      ai.kiro.enable = lib.mkForce false;
      ai.programs.delegate-routing.runtimes.kiro.models = [{vendors = ["anthropic"];}];
    });
    invalid = evaluate (lib.recursiveUpdate manualScenario {
      ai = {
        kiro.enable = lib.mkForce false;
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
      && passes (change (lib.recursiveUpdate unnamed {
        ai.${target}.enable = lib.mkForce false;
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
    techniqueRow = text: technique: lib.findFirst (lib.hasInfix "`${technique}`") "" (lib.splitString "\n" text);
    kiroInvoke = techniqueRow kiro "invoke_sub_agent";
    # Technique, kind, pins model, pins effort and modes, without table padding.
    techniqueCells = text: technique: lib.sublist 1 5 (map lib.trim (lib.splitString "|" (techniqueRow text technique)));
    # The "Runs own subagents" cell, which follows Modes.
    ownSubagents = text: technique: lib.trim (builtins.elemAt (lib.splitString "|" (techniqueRow text technique)) 6);
    ruleText = value: value.config.ai.claude.extraSystemPrompt.delegate-routing.text;
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
    # A runtime replacement supplies the portable wording explicitly.
    runtimeCatalogEnabled = change {
      ai.programs.delegate-routing.runtimes.claude.routing."Orchestrator session" = {
        always = true;
        enable = true;
        source = ../fragments/orchestrator-session.md;
      };
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
    alwaysDisabled = change {
      ai.programs.delegate-routing.routing = {
        "Load delegate-routing".enable = false;
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
  in {
    "module-delegate-routing-${name}-content" = mkTest "delegate-routing-${name}-content" (
      passes result
      && lib.all (family: lib.hasInfix "${family} (anthropic)" nativeClaude) ["fable" "haiku" "opus" "sonnet"]
      && lib.hasInfix "native" nativeClaude
      && !(lib.hasInfix "(openai)" nativeClaude)
      && lib.all (family: lib.hasInfix "${family} (openai)" claude) ["astra" "luna" "sol" "terra"]
      && lib.hasInfix "via codex external" claude
      && lib.hasInfix "(openai)" codex
      && !(lib.hasInfix "(anthropic)" codex)
      && lib.hasInfix "## manual-only external delegates" claude
      && lib.hasInfix "Not a candidate for auto-selection; use only when the user names it." claude
      && lib.hasInfix "claude-opus-*" claude
      && lib.hasInfix "gpt-*-sol" claude
    );
    # The skill's Kiro evidence covers the v3 engine only: reaching Kiro turns it
    # on by default, the program being off leaves Kiro alone, and an explicit
    # consumer value wins.
    "module-delegate-routing-${name}-kiro-v3" = mkTest "delegate-routing-${name}-kiro-v3" (
      result.config.ai.kiro.v3
      && !(builtins.any (lib.hasInfix "ai.kiro.v3") result.config.warnings)
      && !(change {ai.programs.delegate-routing.enable = false;}).config.ai.kiro.v3
      && (change {ai.programs.delegate-routing.runtimes.kiro.enable = false;}).config.ai.kiro.v3
      && !(change {
        ai.programs.delegate-routing.runtimes = {
          kiro.enable = false;
          claude.manualExternalDelegates = ["kimchi"];
        };
      }).config.ai.kiro.v3
      && (let
        unmanaged = change {ai.kiro.package = null;};
      in
        !unmanaged.config.ai.kiro.v3
        && !(builtins.any (lib.hasInfix "ai.kiro.package is null") unmanaged.config.warnings))
      && (let
        optedOut = change {ai.kiro.v3 = false;};
      in
        !optedOut.config.ai.kiro.v3 && builtins.any (lib.hasInfix "ai.kiro.v3 is false") optedOut.config.warnings)
    );
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
        pinsModel = true;
        pinsEffort = true;
      }) "techniques.Invalid.command"
      && passes (invalidNode {
        kind = "external";
        pinsModel = true;
        pinsEffort = true;
        command = "external-command";
      })
    );
    "module-delegate-routing-${name}-techniques" = mkTest "delegate-routing-${name}-techniques" (
      !(lib.hasInfix "`Agent`" disabledNode)
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
      failsWith invalid "ai.programs.delegate-routing.runtimes.claude.extraRuntimes includes `kiro`, but ai.kiro.enable is false. Enable it with ai.kiro.enable = true."
      && failsWith manualMissingModels "ai.programs.delegate-routing.runtimes.kiro.models must select at least one"
      && passes manualManaged
      && lib.hasInfix "## manual-only external delegates\n\n### kiro\n\n-" (readSkill manualManaged "claude")
      && lib.hasInfix "### kiro techniques" (readSkill manualManaged "claude")
      && passes manualOverlap
      && readSkill manualOverlap "claude" == readSkill manualManaged "claude"
      && failsWith extraProgramDisabledKiroMissingModels "ai.programs.delegate-routing.runtimes.kiro.models must select at least one"
      && passes extraProgramDisabledKiro
    );
    "module-delegate-routing-${name}-manual-external-enable" = mkTest "delegate-routing-${name}-manual-external-enable" (
      failsWith manualRuntimeDisabled "ai.programs.delegate-routing.runtimes.claude.manualExternalDelegates includes `kiro`, but ai.kiro.enable is false. Enable it with ai.kiro.enable = true."
      && passes manualManaged
    );
    "module-delegate-routing-${name}-options" = mkTest "delegate-routing-${name}-options" (
      let
        portable = optionTree result ["ai" "programs" "delegate-routing"];
        perRuntime = portable.runtimes.claude;
      in
        portable ? enable
        && portable ? families
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
      && !(disabled.config.ai.codex.extraSystemPrompt ? delegate-routing)
      && disabled.config.ai.claude.skills ? delegate-routing
      && !(result.config.ai.skills ? delegate-routing)
      && !(result.config.ai.extraSystemPrompt ? delegate-routing)
    );
    "module-delegate-routing-${name}-routing-defaults" = mkTest "delegate-routing-${name}-routing-defaults" (
      builtins.attrNames (lib.filterAttrs (_: entry: entry.enable) routingDefaults)
      == ["Choose execution" "Follow the user's request" "Load delegate-routing" "Size the work" "Validate the result"]
      && !routingDefaults."Orchestrator session".enable
      && routingDefaults."Load delegate-routing".always
      && routingDefaults."Validate the result".always
      && ordered claude ["Follow the user's request" "Size the work" "Choose execution"]
      && lib.hasInfix "## Routing" claude
      && hasLoadInstruction stub
      && lib.hasInfix "### Validate the result" stub
      && !(lib.hasInfix "### Load delegate-routing" claude)
      && !(lib.hasInfix "### Validate the result" claude)
      && !(lib.hasInfix "### Size the work" stub)
      && !(alwaysDisabled.config.ai.claude.extraSystemPrompt ? delegate-routing)
      && !(alwaysDisabled.config.ai.codex.extraSystemPrompt ? delegate-routing)
      && !(alwaysDisabled.config.ai.kiro.rules ? delegate-routing-router)
      && lib.hasInfix "## Routing" (readSkill alwaysDisabled "claude")
      # Kiro keeps an always-on rule; the others take the system-prompt entry.
      && lib.all (runtime: result.config.ai.${runtime}.extraSystemPrompt.delegate-routing.text == stub && !(result.config.ai.${runtime}.rules ? delegate-routing-router)) (lib.remove "kiro" runtimes)
      && result.config.ai.kiro.rules.delegate-routing-router.text == stub
      && !(result.config.ai.kiro.extraSystemPrompt ? delegate-routing)
    );
    "module-delegate-routing-${name}-reminder" = mkTest "delegate-routing-${name}-reminder" (
      result.config.ai.programs.delegate-routing.reminder.enable
      && lib.hasInfix "delegate-routing skill" result.config.ai.programs.delegate-routing.reminder.text
      && lib.all (hasReminder result) hookRuntimes
      && lib.all (runtime: !(hasReminder result runtime)) (lib.subtractLists hookRuntimes runtimes)
      && lib.all (runtime: !(hasReminder reminderOff runtime)) runtimes
      && failsWith reminderOnlyClaudeEmpty "ai.programs.delegate-routing.reminder.text"
      && hasReminder reminderOnlyClaude "claude"
      && !(hasReminder reminderOnlyClaude "codex")
      && !(hasReminder reminderOffForCodex "codex")
      && hasReminder reminderOffForCodex "claude"
      && !(hasReminder disabled "codex")
      && reminderCommands reminderCustom "claude" != reminderCommands result "claude"
    );
    "module-delegate-routing-${name}-routing-consumer" = mkTest "delegate-routing-${name}-routing-consumer" (
      !(lib.hasInfix "### Size the work" (readSkill routingDisabled "claude"))
      && lib.hasInfix "### Follow the user's request" (readSkill routingDisabled "claude")
      && lib.hasInfix "### Choose execution" (readSkill routingDisabled "claude")
      && lib.hasInfix "CUSTOM REQUEST GUIDANCE" (readSkill routingReplaced "claude")
      && lib.hasInfix "### Size the work" (readSkill routingReplaced "claude")
      && lib.hasInfix "### Choose execution" (readSkill routingReplaced "claude")
      && ordered (readSkill routingInserted "claude") ["Follow the user's request" "Size the work" "Consumer guidance" "Choose execution"]
      && lib.hasInfix "CUSTOM INSERTED GUIDANCE" (readSkill routingInserted "claude")
    );
    "module-delegate-routing-${name}-routing-runtime" = mkTest "delegate-routing-${name}-routing-runtime" (
      lib.hasInfix "CLAUDE GUIDANCE" (readSkill runtimeRouting "claude")
      && !(lib.hasInfix "PORTABLE GUIDANCE" (readSkill runtimeRouting "claude"))
      && !(lib.hasInfix "### Portable guidance" (ruleText runtimeRouting))
      && lib.hasInfix "PORTABLE GUIDANCE" runtimeRouting.config.ai.codex.extraSystemPrompt.delegate-routing.text
      && !(lib.hasInfix "### Size the work" (readSkill runtimeRouting "claude"))
      && lib.hasInfix "### Size the work" (readSkill runtimeRouting "codex")
      && lib.hasInfix "### Orchestrator session" (ruleText runtimeCatalogEnabled)
      && !(lib.hasInfix "### Orchestrator session" runtimeCatalogEnabled.config.ai.codex.extraSystemPrompt.delegate-routing.text)
    );
    "module-delegate-routing-${name}-workflows" = mkTest "delegate-routing-${name}-workflows" (
      result.config.ai.programs.delegate-routing.workflows.${workflowName}.enable
      && lib.hasInfix "## Common workflows" claude
      && lib.hasInfix "### ${workflowName}" claude
      && lib.hasInfix "### ${workflowName}" codex
      && lib.hasInfix workflowHeader claude
      && lib.hasInfix "1. **Rubric:**" claude
      && lib.hasInfix "8. **Loop:**" claude
      && lib.hasInfix workflowHeader (readSkill runtimeWorkflowStep "claude")
      && lib.hasInfix "CLAUDE WORKFLOW STEP" (readSkill runtimeWorkflowStep "claude")
      && lib.hasInfix "8. **Loop:**" (readSkill runtimeWorkflowStep "claude")
      && lib.hasInfix "CLAUDE CATALOG INTRO" (readSkill runtimeCatalogHeader "claude")
      && !(lib.hasInfix workflowHeader (readSkill runtimeCatalogHeader "claude"))
      && lib.hasInfix "1. **Rubric:**" (readSkill runtimeCatalogHeader "claude")
      && lib.hasInfix "8. **Loop:**" (readSkill runtimeCatalogHeader "claude")
      && !(lib.hasInfix "CLAUDE CATALOG INTRO" (readSkill runtimeCatalogHeader "codex"))
      && !(lib.hasInfix "### ${workflowName}" (readSkill runtimeWorkflowDisabled "claude"))
      && lib.hasInfix "### ${workflowName}" (readSkill runtimeWorkflowDisabled "codex")
      && !catalogOverridden.config.ai.programs.delegate-routing.routing."Orchestrator session".enable
      && !(lib.hasInfix "CUSTOM ORCHESTRATOR GUIDANCE" (readSkill catalogOverridden "claude"))
      && lib.hasInfix "CUSTOM WORKFLOW STEP" (readSkill workflowInserted "claude")
      && (let
        text = readSkill workflowInserted "claude";
        rubric = builtins.head (lib.splitString "CUSTOM WORKFLOW STEP" text);
        remainder = builtins.elemAt (lib.splitString "CUSTOM WORKFLOW STEP" text) 1;
      in
        lib.hasInfix "Rubric" rubric && lib.hasInfix "Review" remainder)
    );
    "module-delegate-routing-${name}-workflow-runtime" = mkTest "delegate-routing-${name}-workflow-runtime" (
      let
        text = readSkill runtimeWorkflow "claude";
        codexRule = runtimeWorkflow.config.ai.codex.extraSystemPrompt.delegate-routing.text;
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
        }).config.ai.claude.extraSystemPrompt.delegate-routing.text
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
