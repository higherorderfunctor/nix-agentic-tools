# cspell:ignore Prio
# Exercise the generated files as delivered through both consumer backends.
{
  harness,
  lib,
  ...
}: let
  inherit (harness) evalDevenv evalDevenvWithSpecialArgs evalHm evalHmWithSpecialArgs hmLib mkTest;
  runtimes = ["claude" "codex" "kiro"];
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
    claude = {
      enable = true;
      programs.delegate-routing = {
        extraRuntimes = ["codex"];
        manualExternalDelegates = ["kiro"];
      };
    };
    codex.enable = true;
    kiro.enable = true;
    programs.delegate-routing.enable = true;
  };
  hasLoadInstruction = text: lib.hasInfix "load the `delegate-routing` skill" (lib.replaceStrings ["\n"] [" "] text);
  nativeDelegateTools = {
    claude = "Use Workflow `agent(prompt, {model, effort})`";
    codex = "Call `collaboration.spawn_agent`";
    kiro = "Set `modelId` and `effortLevel`";
  };
  presets = import ../lib/presets.nix {
    claudeUsageScript = "/nix/store/test-claude-usage";
    codexUsageScript = "/nix/store/test-codex-usage";
  };
  readSkill = result: runtime: builtins.readFile "${result.config.ai.${runtime}.skills.delegate-routing}/SKILL.md";
  render = args: import ../lib/render.nix ({inherit lib presets;} // args);
  renderKiro = kiroModels:
    render {
      inherit kiroModels;
      runtime = "kiro";
    };
  renderedAllRuntimes = lib.genAttrs runtimes (runtime:
    render {
      inherit runtime;
      extraRuntimes = lib.remove runtime runtimes;
    });
  opusRow = "Opus 5.5 (anthropic)";
  optionTree = result: path: (lib.getAttrFromPath path result.options).type.getSubOptions [];
  checkBackend = {
    name,
    evaluate,
    evaluateWarnings ? evaluate,
  }: let
    result = evaluate scenario;
    claude = readSkill result "claude";
    codex = readSkill result "codex";
    kiro = readSkill result "kiro";
    stub = result.config.ai.claude.rules.delegate-routing-router.text;
    disabled = evaluate {
      ai.programs.delegate-routing.enable = true;
      ai.codex.programs.delegate-routing.enable = false;
    };
    manualScenario = {
      ai = {
        claude = {
          enable = true;
          programs.delegate-routing = {
            enable = true;
            manualExternalDelegates = ["kiro"];
          };
        };
        kiro.enable = lib.mkForce false;
      };
    };
    manualDisabled = evaluate manualScenario;
    manualOverlap = evaluate (lib.recursiveUpdate manualScenario {
      ai.claude.programs.delegate-routing.extraRuntimes = ["kiro"];
    });
    invalid = evaluate {
      ai = {
        claude = {
          enable = true;
          programs.delegate-routing = {
            enable = true;
            extraRuntimes = ["kiro"];
          };
        };
        kiro.enable = lib.mkForce false;
      };
    };
    failed = builtins.filter (item: !item.assertion) invalid.config.assertions;
    invalidChecked = assert lib.assertMsg (failed == [])
    (lib.concatMapStringsSep "\n" (item: item.message) failed); true;
    customized = evaluate (lib.recursiveUpdate scenario {
      ai = {
        claude.programs.delegate-routing.settings = {
          checkUsage.enable = false;
          delegateTools.text = "CUSTOM CLAUDE DELEGATION";
          introspectModels.enable = false;
        };
        codex.programs.delegate-routing.settings.launch.text = "CUSTOM CODEX LAUNCH";
        kiro.programs.delegate-routing.settings = {
          introspectModels.enable = false;
          launch.enable = false;
        };
      };
    });
    customizedClaude = readSkill customized "claude";
    kiroWithOpus = renderKiro ["claude-opus-5.5"];
    kiroWithoutOpus = renderKiro [];
    kiroWithLagging = renderKiro ["claude-sonnet-5" "gpt-5.6-luna" "gpt-5.6-sol"];
    catalogIntersectionChecked = assert lib.assertMsg
    (
      lib.hasInfix opusRow kiroWithOpus
      && !(lib.hasInfix opusRow kiroWithoutOpus)
      && !(lib.hasInfix "Sonnet 5.5 (anthropic)" kiroWithLagging)
      && !(lib.hasInfix "Luna (GPT-6) (openai)" kiroWithLagging)
      && !(lib.hasInfix "Sol (GPT-6.1) (openai)" kiroWithLagging)
    )
    "delegate-routing Kiro catalog intersection must include present models and exclude absent models"; true;
    nativeDelegateToolsChecked = assert lib.assertMsg
    (lib.all
      (runtime:
        lib.all
        (other: other == runtime || !(lib.hasInfix nativeDelegateTools.${other} renderedAllRuntimes.${runtime}))
        runtimes)
      runtimes)
    "delegate-routing rendered skills must not contain another runtime's native delegate tools"; true;
    settingsDefaultsChecked = assert lib.assertMsg
    (lib.all
      (runtime:
        lib.all
        (setting:
          result.config.ai.${runtime}.programs.delegate-routing.settings.${setting}.enable
          == !(runtime == "kiro" && setting == "checkUsage"))
        (builtins.attrNames presets.${runtime}))
      runtimes)
    "delegate-routing-${name}: settings blocks must default enabled except kiro.checkUsage"; true;
    noEntries = evaluate scenario;
    shippedPresets = noEntries.config.ai.programs.delegate-routing.whenToDelegate;
    shippedPresetNames = builtins.attrNames shippedPresets;
    shippedPresetFieldDefinitions = preset:
      lib.modules.mergeAttrDefinitionsWithPrio {
        type = lib.types.attrsOf lib.types.raw;
        definitionsWithLocations =
          map
          (definition: {
            inherit (definition) file;
            value = definition.value.whenToDelegate.${preset};
          })
          (builtins.filter
            (definition:
              definition.value ? whenToDelegate
              && builtins.hasAttr preset definition.value.whenToDelegate)
            noEntries.options.ai.programs.delegate-routing.definitionsWithLocations);
      };
    shippedPresetPrioritiesChecked = assert lib.assertMsg
    (lib.all
      (preset:
        lib.all
        (field: field.highestPrio == (lib.mkDefault null).priority)
        (builtins.attrValues (shippedPresetFieldDefinitions preset)))
      shippedPresetNames)
    "delegate-routing-${name}: every field defined by package whenToDelegate presets must use lib.mkDefault"; true;
    shippedPresetsDisabledChecked = assert lib.assertMsg
    (lib.all (preset: !shippedPresets.${preset}.enable) shippedPresetNames)
    "delegate-routing-${name}: package whenToDelegate presets must remain disabled until consumer content overrides them"; true;
    enabledShippedPresets = lib.genAttrs shippedPresetNames (preset:
      evaluate (lib.recursiveUpdate scenario {
        ai.programs.delegate-routing.whenToDelegate.${preset}.enable = true;
      }));
    consumerEntry = evaluate (lib.recursiveUpdate scenario {
      ai.programs.delegate-routing.whenToDelegate.Consumer = {
        text = "Delegate when the task is independently verifiable.";
      };
    });
    overriddenShippedPresetName = builtins.head shippedPresetNames;
    overriddenShippedPresetText = "Consumer replacement guidance.";
    overriddenShippedPreset = evaluate (lib.recursiveUpdate scenario {
      ai.programs.delegate-routing.whenToDelegate.${overriddenShippedPresetName}.text = overriddenShippedPresetText;
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
      lib.hasInfix "codex exec --model <slug> --config 'model_reasoning_effort=\"<level>\"' --json --output-last-message <out>.md - < <prompt-file>" claude
      && lib.hasInfix "## manual-only external delegate sizing\n" claude
      && lib.hasInfix "### kiro\n" claude
      && lib.hasInfix "kiro-cli chat --no-interactive --model auto \"<prompt>\"" claude
      && lib.hasInfix "For a Kiro external delegate, follow its launch block below." claude
      && lib.hasInfix "Not a candidate for auto-selection; use only when the user names it." claude
      && lib.hasInfix "(anthropic)" claude
      && lib.hasInfix "(openai)" claude
      && lib.hasInfix "(openai)" codex
      && !(lib.hasInfix "(anthropic)" codex)
      && !(lib.hasInfix "## manual-only" codex)
      && lib.hasInfix "(anthropic)" kiro
      && lib.hasInfix "(openai)" kiro
      && !(lib.hasInfix "## manual-only" kiro)
      && !(lib.hasInfix "via `" kiro)
      && catalogIntersectionChecked
      && nativeDelegateToolsChecked
      && settingsDefaultsChecked
      && lib.hasInfix "/bin/claude-usage`" claude
      && lib.hasInfix "/bin/codex-usage`" codex
      && !(lib.hasInfix "#### kiro usage" kiro)
    );
    "module-delegate-routing-${name}-external-enable" = mkTest "delegate-routing-${name}-external-enable" (
      !(builtins.tryEval invalidChecked).success
      && lib.any
      (item: lib.hasInfix "ai.claude.programs.delegate-routing.extraRuntimes includes `kiro`, but ai.kiro.enable is false" item.message)
      failed
      && lib.all (item: item.assertion) manualDisabled.config.assertions
      && lib.hasInfix "### kiro\n" (readSkill manualDisabled "claude")
      && lib.all (item: item.assertion) manualOverlap.config.assertions
      && readSkill manualOverlap "claude" == readSkill manualDisabled "claude"
    );
    "module-delegate-routing-${name}-options" = mkTest "delegate-routing-${name}-options" (
      let
        portable = optionTree result ["ai" "programs" "delegate-routing"];
        perRuntime = optionTree result ["ai" "claude" "programs" "delegate-routing"];
      in
        portable ? enable
        && portable ? whenToDelegate
        && !(portable ? extraRuntimes)
        && !(portable ? manualExternalDelegates)
        && !(portable ? settings)
        && perRuntime ? extraRuntimes
        && perRuntime ? manualExternalDelegates
        && perRuntime.settings ? launch
        && !(result.options.ai.kimchi.programs ? delegate-routing)
        && !(result.options.ai.copilot.programs ? delegate-routing)
    );
    "module-delegate-routing-${name}-overrides" = mkTest "delegate-routing-${name}-overrides" (
      lib.hasInfix "CUSTOM CLAUDE DELEGATION" customizedClaude
      && lib.hasInfix "CUSTOM CODEX LAUNCH" customizedClaude
      && !(lib.hasInfix "#### claude usage" customizedClaude)
      && !(lib.hasInfix "api.anthropic.com/api/oauth/usage" customizedClaude)
      && !(lib.hasInfix "maxEffortLevel" customizedClaude)
      && !(lib.hasInfix "kiro-cli chat --no-interactive" customizedClaude)
      && !(lib.hasInfix "--model auto" customizedClaude)
      && !(lib.hasInfix "follow its launch block below" customizedClaude)
      && !(lib.hasInfix "_kiro/config/template" customizedClaude)
      && !(disabled.config.ai.codex.skills ? delegate-routing)
      && !(disabled.config.ai.codex.rules ? delegate-routing-router)
      && disabled.config.ai.claude.skills ? delegate-routing
      && !(result.config.ai.skills ? delegate-routing)
      && !(result.config.ai.rules ? delegate-routing-router)
    );
    "module-delegate-routing-${name}-preset-priorities" = mkTest "delegate-routing-${name}-preset-priorities" (
      shippedPresetsDisabledChecked && shippedPresetPrioritiesChecked
    );
    "module-delegate-routing-${name}-stub" = mkTest "delegate-routing-${name}-stub" (
      builtins.length (lib.splitString "\n" (lib.removeSuffix "\n" stub))
      <= 10
      && hasLoadInstruction stub
      && !(lib.hasInfix "Never inherit" stub)
      && lib.all
      (runtime: let
        skill = readSkill result runtime;
      in
        builtins.length (lib.splitString "Never inherit" skill)
        == 2
        && !(hasLoadInstruction skill))
      runtimes
      && lib.all (runtime: result.config.ai.${runtime}.rules.delegate-routing-router.text == stub) runtimes
    );
    "module-delegate-routing-${name}-when-to-delegate" = mkTest "delegate-routing-${name}-when-to-delegate" (
      ruleText noEntries
      == builtins.readFile ../fragments/skill-routing.md
      && lib.hasInfix "### Consumer\n\nDelegate when the task is independently verifiable." (ruleText consumerEntry)
      && lib.hasInfix "### ${overriddenShippedPresetName}\n\n${overriddenShippedPresetText}" (ruleText overriddenShippedPreset)
      && !(lib.hasInfix (lib.removeSuffix "\n" (builtins.readFile shippedPresets.${overriddenShippedPresetName}.source)) (ruleText overriddenShippedPreset))
      && !(lib.hasInfix "### Preset" (ruleText disabledPreset))
      && lib.hasInfix "### Preset\n\nDelegate a preset task." (ruleText enabledPreset)
      && lib.all
      (preset: let
        declaredSource = shippedPresets.${preset}.source;
        text = ruleText enabledShippedPresets.${preset};
      in
        lib.hasInfix
        "### ${preset}\n\n${lib.removeSuffix "\n" (builtins.readFile declaredSource)}"
        text
        && lib.all
        (other:
          other
          == preset
          || !(lib.hasInfix (lib.removeSuffix "\n" (builtins.readFile shippedPresets.${other}.source)) text))
        shippedPresetNames)
      shippedPresetNames
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
