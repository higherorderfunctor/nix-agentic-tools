# cspell:ignore Prio sublist
# Exercise the generated files as delivered through both consumer backends.
{
  harness,
  lib,
  ...
}: let
  inherit (harness) evalDevenv evalDevenvWithSpecialArgs evalHm evalHmWithSpecialArgs hmLib mkTest;
  runtimes = ["claude" "codex" "kimchi" "kiro"];
  testRenames."Old guidance" = "New guidance";
  warningMarker = "delegate-routing fallback warning: ";
  evalDevenvWarnings = evalDevenvWithSpecialArgs {
    delegateRoutingRenames = testRenames;
    lib =
      hmLib
      // {
        warn = warning: value:
          value
          ++ [
            {
              assertion = true;
              message = "${warningMarker}${warning}";
            }
          ];
      };
  };
  evalHmWarnings = evalHmWithSpecialArgs {delegateRoutingRenames = testRenames;};
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
      settings = {
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
  hasLoadInstruction = text: lib.hasInfix "load the `delegate-routing` skill" (lib.replaceStrings ["\n"] [" "] text);
  crossVendor = "Rows span more than one vendor";
  readSkill = result: runtime: builtins.readFile "${result.config.ai.${runtime}.skills.delegate-routing}/SKILL.md";
  optionTree = result: path: lib.getAttrFromPath path result.options;
  checkBackend = {
    name,
    evaluate,
    evaluateWarnings ? evaluate,
  }: let
    result = evaluate scenario;
    claude = readSkill result "claude";
    codex = readSkill result "codex";
    kimchi = readSkill result "kimchi";
    kiro = readSkill result "kiro";
    stub = result.config.ai.claude.rules.delegate-routing-router.text;
    change = config: evaluate (lib.recursiveUpdate scenario config);
    skill = config: readSkill (change config) "claude";
    passes = evaluation: lib.all (item: item.assertion) evaluation.config.assertions;
    failsWith = evaluation: option: lib.any (item: !item.assertion && lib.hasInfix option item.message) evaluation.config.assertions;
    evaluationFails = evaluation: !(builtins.tryEval (builtins.deepSeq evaluation.config.ai.programs.delegate-routing.settings.claude true)).success;
    roleScenario = roles: extras: manual:
      change {
        ai.programs.delegate-routing.settings.claude = {
          inherit roles;
          extraRuntimes = extras;
          manualExternalDelegates = manual;
        };
      };
    configuredRoles = {
      default = {
        effort = "medium";
        use = "strong";
      };
      reviewer = {
        effort = "high";
        use = "opus";
      };
      writer = {use = "sol";};
    };
    hasProse = needle: text: lib.hasInfix needle (lib.replaceStrings ["\n"] [" "] text);
    rolesSkill = readSkill (roleScenario configuredRoles ["codex"] []) "claude";
    loneRuntime = runtime:
      readSkill (change {
        ai.programs.delegate-routing.settings.${runtime} = {
          extraRuntimes = [];
          manualExternalDelegates = [];
        };
      })
      runtime;
    native = change {ai.programs.delegate-routing.settings.claude.extraRuntimes = [];};
    nativeClaude = readSkill native "claude";
    disabled = evaluate {
      ai.programs.delegate-routing.enable = true;
      ai.programs.delegate-routing.settings.codex.enable = false;
    };
    manualScenario.ai = {
      claude.enable = true;
      kiro.enable = lib.mkForce false;
      programs.delegate-routing.settings.claude = {
        enable = true;
        manualExternalDelegates = ["kiro"];
      };
    };
    manualMissingModels = evaluate manualScenario;
    manualDisabled = evaluate (lib.recursiveUpdate manualScenario {
      ai.programs.delegate-routing.settings.kiro.models = [{vendors = ["anthropic"];}];
    });
    manualOverlap = evaluate (lib.recursiveUpdate manualScenario {
      ai.programs.delegate-routing.settings.claude.extraRuntimes = ["kiro"];
      ai.programs.delegate-routing.settings.kiro.models = [{vendors = ["anthropic"];}];
    });
    invalid = evaluate (lib.recursiveUpdate manualScenario {
      ai = {
        programs.delegate-routing.settings.claude = {
          extraRuntimes = ["kiro"];
          manualExternalDelegates = [];
        };
        programs.delegate-routing.settings.kiro.models = [{vendors = ["anthropic"];}];
      };
    });
    # A runtime with no default selection must choose one when its program and
    # runtime are enabled, and needs none once either is off and Claude no
    # longer names it.
    requiresSelection = target: let
      unnamed.ai.programs.delegate-routing.settings.claude.manualExternalDelegates =
        lib.remove target scenario.ai.programs.delegate-routing.settings.claude.manualExternalDelegates;
    in
      failsWith (change {ai.programs.delegate-routing.settings.${target}.models = [];}) "ai.programs.delegate-routing.settings.${target}.models must select at least one"
      && passes (change (lib.recursiveUpdate unnamed {
        ai.${target}.enable = lib.mkForce false;
        ai.programs.delegate-routing.settings.${target}.models = [];
      }))
      && passes (change (lib.recursiveUpdate unnamed {
        ai.programs.delegate-routing.settings.${target} = {
          enable = false;
          models = [];
        };
      }));
    extraProgramDisabledKiroMissingModels = change {
      ai = {
        programs.delegate-routing.settings.claude = {
          extraRuntimes = ["kiro"];
          manualExternalDelegates = [];
        };
        programs.delegate-routing.settings.kiro = {
          enable = false;
          models = [];
        };
      };
    };
    extraProgramDisabledKiro = change {
      ai = {
        programs.delegate-routing.settings.claude = {
          extraRuntimes = ["kiro"];
          manualExternalDelegates = [];
        };
        programs.delegate-routing.settings.kiro = {
          enable = false;
          models = [{vendors = ["anthropic"];}];
        };
      };
    };
    selector = value: change {ai.programs.delegate-routing.settings.claude.models = [value];};
    familyOverride = skill {ai.programs.delegate-routing.families.anthropic.opus.useFor = "CUSTOM OPUS TASK";};
    addedFamily = skill {
      ai = {
        programs.delegate-routing.families.example.x = {
          match = "example-x-*";
          tier = "strong";
          useFor = "CUSTOM FAMILY TASK";
        };
        programs.delegate-routing.settings.claude.models = [{families = ["x"];}];
      };
    };
    disabledNode = skill {ai.programs.delegate-routing.settings.claude.techniques.Agent.enable = false;};
    modifiedNode = skill {ai.programs.delegate-routing.settings.codex.techniques."codex exec".command = "CUSTOM CODEX COMMAND";};
    invalidNode = node: change {ai.programs.delegate-routing.settings.claude.techniques.Invalid = node;};
    replacedText = key: field: value: skill {ai.programs.delegate-routing.${key}.${field} = value;};
    techniqueRow = text: technique: lib.findFirst (lib.hasInfix "`${technique}`") "" (lib.splitString "\n" text);
    kiroInvoke = techniqueRow kiro "invoke_sub_agent";
    # Technique, kind, pins model, pins effort and modes, without table padding.
    techniqueCells = text: technique: lib.sublist 1 5 (map lib.trim (lib.splitString "|" (techniqueRow text technique)));
    noEntries = evaluate scenario;
    shippedEntries = noEntries.config.ai.programs.delegate-routing.whenToDelegate;
    shippedEntryNames = builtins.attrNames shippedEntries;
    shippedEntryFieldDefinitions = preset:
      lib.modules.mergeAttrDefinitionsWithPrio {
        type = lib.types.attrsOf lib.types.raw;
        definitionsWithLocations =
          map
          (definition: {
            inherit (definition) file;
            value = definition.value.${preset};
          })
          (builtins.filter
            (definition:
              builtins.hasAttr preset definition.value)
            noEntries.options.ai.programs.delegate-routing.whenToDelegate.definitionsWithLocations);
      };
    shippedEntryPrioritiesChecked = assert lib.assertMsg
    (lib.all
      (preset:
        lib.all
        (field: field.highestPrio == (lib.mkDefault null).priority)
        (builtins.attrValues (shippedEntryFieldDefinitions preset)))
      shippedEntryNames)
    "delegate-routing-${name}: every field defined by package whenToDelegate defaults must use lib.mkDefault"; true;
    shippedEntriesDisabledChecked = assert lib.assertMsg
    (lib.all (preset: !shippedEntries.${preset}.enable) shippedEntryNames)
    "delegate-routing-${name}: package whenToDelegate defaults must remain disabled until consumer content overrides them"; true;
    enabledShippedEntries = lib.genAttrs shippedEntryNames (preset:
      evaluate (lib.recursiveUpdate scenario {
        ai.programs.delegate-routing.whenToDelegate.${preset}.enable = true;
      }));
    consumerEntry = evaluate (lib.recursiveUpdate scenario {
      ai.programs.delegate-routing.whenToDelegate.Consumer = {
        text = "Delegate when the task is independently verifiable.";
      };
    });
    overriddenShippedEntryName = builtins.head shippedEntryNames;
    overriddenShippedEntryText = "Consumer replacement guidance.";
    overriddenShippedEntry = evaluate (lib.recursiveUpdate scenario {
      ai.programs.delegate-routing.whenToDelegate.${overriddenShippedEntryName}.text = overriddenShippedEntryText;
    });
    disabledPreset = evaluate (lib.recursiveUpdate scenario {
      ai.programs.delegate-routing.whenToDelegate.Preset = {
        enable = lib.mkDefault false;
        text = lib.mkDefault "Delegate a preset task.";
      };
    });
    enabledPreset = evaluate (lib.recursiveUpdate scenario {
      ai.programs.delegate-routing.whenToDelegate.Preset = {
        enable = true;
        text = lib.mkDefault "Delegate a preset task.";
      };
    });
    explicitlyDisabled = evaluate (lib.recursiveUpdate scenario {
      ai.programs.delegate-routing.whenToDelegate.Intentional = {
        enable = lib.mkMerge [(lib.mkDefault false) false];
        text = "Consumer guidance.";
      };
    });
    packageWhenToDelegateOptions = import ../lib/when-to-delegate.nix {
      inherit lib;
      renames = import ../lib/when-to-delegate-renames.nix;
    };
    presetSource = ../fragments/skill-routing.md;
    sourcePreset = packageWhenToDelegateOptions.mkPreset {source = presetSource;};
    textPreset = packageWhenToDelegateOptions.mkPreset {text = "Delegate a preset task.";};
    presetEvaluation = lib.evalModules {
      modules = [
        {
          options.entries = lib.mkOption {
            inherit (packageWhenToDelegateOptions) type;
            default = {};
          };
          config.entries = {
            Source = sourcePreset;
            Text = textPreset;
          };
        }
      ];
    };
    presetConstructorContract = let
      defaultPriority = (lib.mkDefault null).priority;
      entriesDisabledChecked = assert lib.assertMsg
      (!presetEvaluation.config.entries.Source.enable && !presetEvaluation.config.entries.Text.enable)
      "delegate-routing mkPreset content must not auto-enable preset entries"; true;
      neitherFailed = !(builtins.tryEval (packageWhenToDelegateOptions.mkPreset {})).success;
      sourceDefaultChecked = assert lib.assertMsg
      (
        sourcePreset.source.priority
        == defaultPriority
        && sourcePreset.source.content == presetSource
        && presetEvaluation.config.entries.Source.source == presetSource
      )
      "delegate-routing mkPreset source must use mkDefault priority and preserve its value"; true;
      textDefaultChecked = assert lib.assertMsg
      (
        textPreset.text.priority
        == defaultPriority
        && textPreset.text.content == "Delegate a preset task."
        && presetEvaluation.config.entries.Text.text == "Delegate a preset task."
      )
      "delegate-routing mkPreset text must use mkDefault priority and preserve its value"; true;
      bothFailed =
        !(builtins.tryEval (packageWhenToDelegateOptions.mkPreset {
          source = presetSource;
          text = "Conflicting preset task.";
        })).success;
    in
      entriesDisabledChecked
      && sourceDefaultChecked
      && textDefaultChecked
      && bothFailed
      && neitherFailed;
    packageRenamed = evaluateWarnings (lib.recursiveUpdate scenario {
      ai.programs.delegate-routing.whenToDelegate."Old guidance".text = "Renamed consumer guidance.";
    });
    packageRenameWarning = "ai.programs.delegate-routing.whenToDelegate.Old guidance has been renamed to ai.programs.delegate-routing.whenToDelegate.New guidance; update the attribute name.";
    testWhenToDelegateOptions = import ../lib/when-to-delegate.nix {
      inherit lib;
      renames."Old guidance" = "New guidance";
    };
    renamed = lib.evalModules {
      modules = [
        {
          options.entries = lib.mkOption {
            inherit (testWhenToDelegateOptions) type;
            default = {};
            apply = testWhenToDelegateOptions.rename;
          };
          config.entries."Old guidance".text = "Renamed consumer guidance.";
        }
      ];
    };
    renamedEntries = renamed.config.entries;
    renamedRuleText =
      (import ../router.nix {
        entries = renamedEntries;
        inherit lib;
      }).delegate-routing-router.text;
    renamedWarnings = testWhenToDelegateOptions.warnings renamedEntries;
    ruleText = value: value.config.ai.claude.rules.delegate-routing-router.text;
    whenToDelegateWarnings = value: packageWhenToDelegateOptions.warnings value.config.ai.programs.delegate-routing.whenToDelegate;
    warningDeliveryContract = label: evaluation: warning:
      if evaluation.options ? warnings
      then
        if evaluation.config.warnings == [warning]
        then true
        else throw "delegate-routing-${name}: ${label} warning was not exposed through config.warnings"
      else let
        captured = map (item: lib.removePrefix warningMarker item.message) (
          builtins.filter
          (item: lib.hasPrefix warningMarker item.message)
          evaluation.config.assertions
        );
      in
        if captured == [warning]
        then true
        else throw "delegate-routing-${name}: ${label} warning did not use the lib.warn fallback";
    protectionContract =
      if whenToDelegateWarnings explicitlyDisabled != []
      then throw "delegate-routing-${name}: explicitly disabled consumer entry unexpectedly warned"
      else if lib.hasInfix "### Intentional" (ruleText explicitlyDisabled)
      then throw "delegate-routing-${name}: explicitly disabled consumer entry rendered"
      else if !(lib.hasInfix "### New guidance\n\nRenamed consumer guidance." renamedRuleText)
      then throw "delegate-routing-${name}: renamed entry did not render under the new key"
      else if lib.hasInfix "### Old guidance" renamedRuleText
      then throw "delegate-routing-${name}: renamed entry still rendered under the old key"
      else if renamedWarnings != ["ai.programs.delegate-routing.whenToDelegate.Old guidance has been renamed to ai.programs.delegate-routing.whenToDelegate.New guidance; update the attribute name."]
      then throw "delegate-routing-${name}: rename did not produce exactly one warning"
      else if !(warningDeliveryContract "rename" packageRenamed packageRenameWarning)
      then false
      else true;
  in {
    "module-delegate-routing-${name}-content" = mkTest "delegate-routing-${name}-content" (
      passes result
      && lib.all (family: lib.hasInfix "${family} (anthropic)" nativeClaude) ["fable" "haiku" "opus" "sonnet"]
      && lib.hasInfix "native" nativeClaude
      && !(lib.hasInfix "(openai)" nativeClaude)
      && !(lib.hasInfix crossVendor nativeClaude)
      && lib.all (family: lib.hasInfix "${family} (openai)" claude) ["astra" "luna" "sol" "terra"]
      && lib.hasInfix "via codex external" claude
      && lib.hasInfix crossVendor claude
      && lib.hasInfix "(openai)" codex
      && !(lib.hasInfix "(anthropic)" codex)
      && !(lib.hasInfix crossVendor codex)
      && lib.hasInfix "## manual-only external delegates" claude
      && lib.hasInfix "Not a candidate for auto-selection; use only when the user names it." claude
      && lib.hasInfix "claude-opus-*" claude
      && lib.hasInfix "gpt-*-sol" claude
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
            path = ["ai" "programs" "delegate-routing" "settings"];
            update = settings: builtins.removeAttrs settings ["kimchi"];
          }
        ]
        scenario)) "ai.programs.delegate-routing.settings.kimchi.models must select at least one"
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
          programs.delegate-routing.settings.claude.models = [
            {families = ["opus"];}
            {tiers = ["frontier"];}
          ];
        };
      })
      && failsWith (selector {}) "ai.programs.delegate-routing.settings.claude.models contains an empty selector"
      && failsWith (selector {
        vendors = ["openai"];
        families = ["opus"];
      }) "ai.programs.delegate-routing.settings.claude.models must select"
      && passes (selector {
        vendors = ["anthropic"];
        tiers = ["strong" "small"];
      })
      && (let
        union = skill {
          ai.programs.delegate-routing.settings.claude = {
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
    "module-delegate-routing-${name}-roles" = mkTest "delegate-routing-${name}-roles" (
      evaluationFails (roleScenario {default.use = "asdf";} [] [])
      && evaluationFails (roleScenario {default.use = "sol";} [] [])
      && evaluationFails (roleScenario {default.use = "sol";} ["codex"] ["codex"])
      && evaluationFails (roleScenario {
        default = {
          effort = "ultra";
          use = "strong";
        };
      } [] [])
      && passes (roleScenario {default.use = "strong";} [] [])
      && passes (roleScenario {default.use = "opus";} [] [])
      && passes (roleScenario {default.use = "sol";} ["codex"] [])
      && passes (roleScenario {
        default.use = "small";
        reviewer.use = "frontier";
        writer.use = "opus";
      } [] [])
      && hasProse "Strong is the ceiling:" (readSkill (roleScenario {default.use = "opus";} [] []) "claude")
      && failsWith (change {
        ai.programs.delegate-routing.families.example.strong = {
          match = "example-*";
          tier = "small";
        };
      }) "family names must be unique across vendors and must not equal a capability tier"
      && failsWith (change {
        ai.programs.delegate-routing.families.example.opus = {
          match = "example-opus-*";
          tier = "small";
        };
      }) "family names must be unique across vendors and must not equal a capability tier"
      && hasProse "Default for reasoning work: strong at medium" rolesSkill
      && hasProse "Writer: sol at medium" rolesSkill
      && hasProse "Reviewer: opus at high" rolesSkill
      && hasProse "Strong is the ceiling: go above it only when the user asks" rolesSkill
      && hasProse "Mechanical work still goes to the small tier (rule 1)" rolesSkill
      && hasProse "Configured writer and reviewer roles count as the user asking." rolesSkill
      && (let
        writerOnly = readSkill (roleScenario {
          writer = {
            effort = "high";
            use = "opus";
          };
        } [] []) "claude";
      in
        hasProse "Writer: opus at high." writerOnly
        && hasProse "Configured writer and reviewer roles count as the user asking." writerOnly)
      && hasProse "Configured writer and reviewer roles count as the user asking." (readSkill (roleScenario {reviewer.use = "opus";} [] []) "claude")
      && !(hasProse "is the ceiling:" (readSkill (roleScenario {writer.use = "opus";} [] []) "claude"))
      && hasProse "Reviewer: opus at medium." (readSkill (roleScenario {
        default = {
          effort = "medium";
          use = "opus";
        };
        reviewer.use = "opus";
      } [] []) "claude")
      && !(hasProse "**Roles.**" claude)
      && lib.all (runtime: !(hasProse "among close candidates, prefer the pool" (loneRuntime runtime))) ["claude" "kiro"]
      && hasProse "among close candidates, prefer the pool" claude
      && !(hasProse "among close candidates, prefer the pool" (readSkill (roleScenario {} [] []) "claude"))
      && hasProse "comparing version numbers segment by segment (6.1 > 6 > 5.6)" claude
      && hasProse "Use a technique only if it appears in your tool list" claude
      && hasProse "an agent cannot reliably tell which mode it is in, but it can see its tools" claude
      && techniqueCells kiro "orchestrate_subagent" == ["`orchestrate_subagent`" "subagent" "false" "false" "interactive+acp"]
      && hasProse "some ACP clients enable it in place of invoke_sub_agent" kiro
      && lib.all (runtime: let value = result.config.ai.programs.delegate-routing.settings.${runtime}.roles; in value.default == null && value.writer == null && value.reviewer == null) runtimes
    );
    "module-delegate-routing-${name}-families" = mkTest "delegate-routing-${name}-families" (
      lib.hasInfix "CUSTOM OPUS TASK" familyOverride
      && lib.hasInfix "x (example)" addedFamily
      && lib.hasInfix "example-x-*" addedFamily
      && lib.hasInfix "CUSTOM FAMILY TASK" addedFamily
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
    );
    "module-delegate-routing-${name}-text" = mkTest "delegate-routing-${name}-text" (
      lib.all (key: let
        marker =
          if key == "rules"
          then "Size every delegate"
          else "## procedure";
        replacement = replacedText key "text" "CUSTOM TEXT BLOCK";
        sourced = replacedText key "source" ../fragments/skill-routing.md;
        omitted = replacedText key "enable" false;
      in
        lib.hasInfix "CUSTOM TEXT BLOCK" replacement
        && !(lib.hasInfix marker replacement)
        && hasLoadInstruction sourced
        && !(lib.hasInfix marker sourced)
        && !(lib.hasInfix marker omitted)) ["rules" "procedure"]
    );
    "module-delegate-routing-${name}-external-enable" = mkTest "delegate-routing-${name}-external-enable" (
      failsWith invalid "ai.programs.delegate-routing.settings.claude.extraRuntimes includes `kiro`, but ai.kiro.enable is false"
      && failsWith manualMissingModels "ai.programs.delegate-routing.settings.kiro.models must select at least one"
      && passes manualDisabled
      && lib.hasInfix "## manual-only external delegates\n\n### kiro\n\n-" (readSkill manualDisabled "claude")
      && lib.hasInfix "### kiro techniques" (readSkill manualDisabled "claude")
      && passes manualOverlap
      && readSkill manualOverlap "claude" == readSkill manualDisabled "claude"
      && failsWith extraProgramDisabledKiroMissingModels "ai.programs.delegate-routing.settings.kiro.models must select at least one"
      && passes extraProgramDisabledKiro
    );
    "module-delegate-routing-${name}-options" = mkTest "delegate-routing-${name}-options" (
      let
        portable = optionTree result ["ai" "programs" "delegate-routing"];
        perRuntime = portable.settings.claude;
        roleOptions = perRuntime.roles.type.getSubOptions [];
        defaultRole = roleOptions.default.type.getSubOptions [];
      in
        portable ? enable
        && portable ? whenToDelegate
        && portable ? families
        && portable ? rules
        && portable ? procedure
        && !(portable ? extraRuntimes)
        && !(portable ? manualExternalDelegates)
        && !(portable ? roles)
        && !(portable ? models)
        && !(portable ? techniques)
        && perRuntime ? extraRuntimes
        && perRuntime ? manualExternalDelegates
        && perRuntime ? roles
        && builtins.attrNames (builtins.removeAttrs roleOptions ["_module"]) == ["default" "reviewer" "writer"]
        && defaultRole.use.type.name == "enum"
        && lib.hasInfix "strong" defaultRole.use.type.description
        && lib.hasInfix "opus" defaultRole.use.type.description
        && lib.hasInfix "sol" defaultRole.use.type.description
        && !(lib.hasInfix "flash" defaultRole.use.type.description)
        && perRuntime ? models
        && perRuntime ? techniques
        && portable.settings ? kimchi
        && !(portable.settings ? copilot)
    );
    "module-delegate-routing-${name}-overrides" = mkTest "delegate-routing-${name}-overrides" (
      !(disabled.config.ai.codex.skills ? delegate-routing)
      && !(disabled.config.ai.codex.rules ? delegate-routing-router)
      && disabled.config.ai.claude.skills ? delegate-routing
      && !(result.config.ai.skills ? delegate-routing)
      && !(result.config.ai.rules ? delegate-routing-router)
    );
    "module-delegate-routing-${name}-preset-priorities" = mkTest "delegate-routing-${name}-preset-priorities" (
      shippedEntriesDisabledChecked && shippedEntryPrioritiesChecked
    );
    "module-delegate-routing-${name}-stub" = mkTest "delegate-routing-${name}-stub" (
      builtins.length (lib.splitString "\n" (lib.removeSuffix "\n" stub))
      <= 10
      && hasLoadInstruction stub
      && !(lib.hasInfix "Size every delegate" stub)
      && lib.all (runtime: let
        text = readSkill result runtime;
      in
        builtins.length (lib.splitString "Size every delegate" text) == 2 && !(hasLoadInstruction text))
      runtimes
      && lib.all (runtime: result.config.ai.${runtime}.rules.delegate-routing-router.text == stub) runtimes
    );
    "module-delegate-routing-${name}-when-to-delegate" = mkTest "delegate-routing-${name}-when-to-delegate" (
      ruleText noEntries
      == builtins.readFile ../fragments/skill-routing.md
      && lib.hasInfix "### Consumer\n\nDelegate when the task is independently verifiable." (ruleText consumerEntry)
      && lib.hasInfix "### ${overriddenShippedEntryName}\n\n${overriddenShippedEntryText}" (ruleText overriddenShippedEntry)
      && !(lib.hasInfix (lib.removeSuffix "\n" (builtins.readFile shippedEntries.${overriddenShippedEntryName}.source)) (ruleText overriddenShippedEntry))
      && !(lib.hasInfix "### Preset" (ruleText disabledPreset))
      && lib.hasInfix "### Preset\n\nDelegate a preset task." (ruleText enabledPreset)
      && lib.all
      (preset: let
        declaredSource = shippedEntries.${preset}.source;
        text = ruleText enabledShippedEntries.${preset};
      in
        lib.hasInfix
        "### ${preset}\n\n${lib.removeSuffix "\n" (builtins.readFile declaredSource)}"
        text
        && lib.all
        (other:
          other
          == preset
          || !(lib.hasInfix (lib.removeSuffix "\n" (builtins.readFile shippedEntries.${other}.source)) text))
        shippedEntryNames)
      shippedEntryNames
    );
    "module-delegate-routing-${name}-when-to-delegate-preset-constructor" = mkTest "delegate-routing-${name}-when-to-delegate-preset-constructor" presetConstructorContract;
    "module-delegate-routing-${name}-when-to-delegate-protection" = mkTest "delegate-routing-${name}-when-to-delegate-protection" protectionContract;
  };
in {
  checks =
    checkBackend {
      name = "devenv";
      evaluate = evalDevenv;
      evaluateWarnings = evalDevenvWarnings;
    }
    // checkBackend {
      name = "hm";
      evaluate = evalHm;
      evaluateWarnings = evalHmWarnings;
    };
}
