# Exercise the generated files as delivered through both consumer backends.
{
  lib,
  harness,
  ...
}: let
  inherit (harness) evalDevenv evalDevenvWithSpecialArgs evalHm evalHmWithSpecialArgs hmLib mkTest;
  runtimes = ["claude" "codex" "kiro"];
  testRenames."Old guidance" = "New guidance";
  warningMarker = "delegate-sizing fallback warning: ";
  evalDevenvWarnings = evalDevenvWithSpecialArgs {
    delegateSizingRenames = testRenames;
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
  evalHmWarnings = evalHmWithSpecialArgs {delegateSizingRenames = testRenames;};
  scenario.ai = {
    claude = {
      enable = true;
      programs.delegate-sizing = {
        extraRuntimes = ["codex"];
        manualExternalDelegates = ["kiro"];
      };
    };
    codex.enable = true;
    kiro.enable = true;
    programs.delegate-sizing.enable = true;
  };
  hasLoadInstruction = text: lib.hasInfix "load the `delegate-sizing` skill" (lib.replaceStrings ["\n"] [" "] text);
  nativeDelegateTools = {
    claude = "Use Workflow `agent(prompt, {model, effort})`";
    codex = "Call `collaboration.spawn_agent`";
    kiro = "Set `modelId` and `effortLevel`";
  };
  presets = import ../lib/presets.nix {
    claudeUsageScript = "/nix/store/test-claude-usage";
    codexUsageScript = "/nix/store/test-codex-usage";
  };
  readSkill = result: runtime: builtins.readFile "${result.config.ai.${runtime}.skills.delegate-sizing}/SKILL.md";
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
  sonnetRow = "Sonnet 5 (anthropic)";
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
    stub = result.config.ai.claude.rules.delegate-sizing-router.text;
    disabled = evaluate {
      ai.programs.delegate-sizing.enable = true;
      ai.codex.programs.delegate-sizing.enable = false;
    };
    manualScenario = {
      ai = {
        claude = {
          enable = true;
          programs.delegate-sizing = {
            enable = true;
            manualExternalDelegates = ["kiro"];
          };
        };
        kiro.enable = lib.mkForce false;
      };
    };
    manualDisabled = evaluate manualScenario;
    manualOverlap = evaluate (lib.recursiveUpdate manualScenario {
      ai.claude.programs.delegate-sizing.extraRuntimes = ["kiro"];
    });
    invalid = evaluate {
      ai = {
        claude = {
          enable = true;
          programs.delegate-sizing = {
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
        claude.programs.delegate-sizing.settings = {
          checkUsage.enable = false;
          delegateTools.text = "CUSTOM CLAUDE DELEGATION";
          introspectModels.enable = false;
        };
        codex.programs.delegate-sizing.settings.launch.text = "CUSTOM CODEX LAUNCH";
        kiro.programs.delegate-sizing.settings = {
          introspectModels.enable = false;
          launch.enable = false;
        };
      };
    });
    customizedClaude = readSkill customized "claude";
    kiroWithSonnet = renderKiro ["claude-sonnet-5"];
    kiroWithoutSonnet = renderKiro [];
    catalogIntersectionChecked = assert lib.assertMsg
    (lib.hasInfix sonnetRow kiroWithSonnet && !(lib.hasInfix sonnetRow kiroWithoutSonnet))
    "delegate-sizing Kiro catalog intersection must include present models and exclude absent models"; true;
    nativeDelegateToolsChecked = assert lib.assertMsg
    (lib.all
      (runtime:
        lib.all
        (other: other == runtime || !(lib.hasInfix nativeDelegateTools.${other} renderedAllRuntimes.${runtime}))
        runtimes)
      runtimes)
    "delegate-sizing rendered skills must not contain another runtime's native delegate tools"; true;
    noEntries = evaluate scenario;
    shippedPresets = noEntries.config.ai.programs.delegate-sizing.whenToDelegate;
    shippedPresetNames = builtins.attrNames shippedPresets;
    shippedPresetSource = preset:
      ../fragments + "/${lib.replaceStrings [" "] ["-"] (lib.toLower preset)}.md";
    enabledShippedPresets = lib.genAttrs shippedPresetNames (preset:
      evaluate (lib.recursiveUpdate scenario {
        ai.programs.delegate-sizing.whenToDelegate.${preset}.enable = true;
      }));
    consumerEntry = evaluate (lib.recursiveUpdate scenario {
      ai.programs.delegate-sizing.whenToDelegate.Consumer = {
        text = "Delegate when the task is independently verifiable.";
      };
    });
    disabledPreset = evaluate (lib.recursiveUpdate scenario {
      ai.programs.delegate-sizing.whenToDelegate.Preset = {
        enable = lib.mkDefault false;
        text = lib.mkDefault "Delegate a preset task.";
      };
    });
    enabledPreset = evaluate (lib.recursiveUpdate scenario {
      ai.programs.delegate-sizing.whenToDelegate.Preset = {
        enable = true;
        text = lib.mkDefault "Delegate a preset task.";
      };
    });
    collision = evaluate (lib.recursiveUpdate scenario {
      ai.programs.delegate-sizing.whenToDelegate.Collision = {
        enable = lib.mkDefault false;
        text = lib.mkMerge [
          (lib.mkDefault "Package guidance.")
          "Consumer guidance."
        ];
      };
    });
    collisionWarning = "ai.programs.delegate-sizing.whenToDelegate.Collision collides with a package preset that defaults to off; choose a different name or set enable = true.";
    explicitlyDisabled = evaluate (lib.recursiveUpdate scenario {
      ai.programs.delegate-sizing.whenToDelegate.Intentional = {
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
      enableDefaultChecked = assert lib.assertMsg
      (
        builtins.isAttrs sourcePreset.enable
        && sourcePreset.enable.priority == defaultPriority
        && presetEvaluation.config.entries.Source.enable == false
      )
      "delegate-sizing mkPreset enable must use mkDefault priority and resolve to false"; true;
      neitherFailed = !(builtins.tryEval (packageWhenToDelegateOptions.mkPreset {})).success;
      sourceDefaultChecked = assert lib.assertMsg
      (
        sourcePreset.source.priority
        == defaultPriority
        && sourcePreset.source.content == presetSource
        && presetEvaluation.config.entries.Source.source == presetSource
      )
      "delegate-sizing mkPreset source must use mkDefault priority and preserve its value"; true;
      textDefaultChecked = assert lib.assertMsg
      (
        textPreset.text.priority
        == defaultPriority
        && textPreset.text.content == "Delegate a preset task."
        && presetEvaluation.config.entries.Text.text == "Delegate a preset task."
      )
      "delegate-sizing mkPreset text must use mkDefault priority and preserve its value"; true;
      bothFailed =
        !(builtins.tryEval (packageWhenToDelegateOptions.mkPreset {
          source = presetSource;
          text = "Conflicting preset task.";
        })).success;
    in
      enableDefaultChecked
      && sourceDefaultChecked
      && textDefaultChecked
      && bothFailed
      && neitherFailed;
    packageRenamed = evaluateWarnings (lib.recursiveUpdate scenario {
      ai.programs.delegate-sizing.whenToDelegate."Old guidance".text = "Renamed consumer guidance.";
    });
    packageRenameWarning = "ai.programs.delegate-sizing.whenToDelegate.Old guidance has been renamed to ai.programs.delegate-sizing.whenToDelegate.New guidance; update the attribute name.";
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
      }).delegate-sizing-router.text;
    renamedWarnings = testWhenToDelegateOptions.warnings renamedEntries;
    ruleText = value: value.config.ai.claude.rules.delegate-sizing-router.text;
    whenToDelegateWarnings = value: packageWhenToDelegateOptions.warnings value.config.ai.programs.delegate-sizing.whenToDelegate;
    collisionWarnings = evaluateWarnings (lib.recursiveUpdate scenario {
      ai.programs.delegate-sizing.whenToDelegate.Collision = {
        enable = lib.mkDefault false;
        text = lib.mkMerge [
          (lib.mkDefault "Package guidance.")
          "Consumer guidance."
        ];
      };
    });
    warningDeliveryContract = label: evaluation: warning:
      if evaluation.options ? warnings
      then
        if evaluation.config.warnings == [warning]
        then true
        else throw "delegate-sizing-${name}: ${label} warning was not exposed through config.warnings"
      else let
        captured = map (item: lib.removePrefix warningMarker item.message) (
          builtins.filter
          (item: lib.hasPrefix warningMarker item.message)
          evaluation.config.assertions
        );
      in
        if captured == [warning]
        then true
        else throw "delegate-sizing-${name}: ${label} warning did not use the lib.warn fallback";
    protectionContract =
      if builtins.length (whenToDelegateWarnings collision) != 1
      then throw "delegate-sizing-${name}: collision did not produce exactly one warning"
      else if builtins.head (whenToDelegateWarnings collision) != collisionWarning
      then throw "delegate-sizing-${name}: collision warning text changed"
      else if whenToDelegateWarnings explicitlyDisabled != []
      then throw "delegate-sizing-${name}: explicitly disabled consumer entry unexpectedly warned"
      else if !(lib.hasInfix "### New guidance\n\nRenamed consumer guidance." renamedRuleText)
      then throw "delegate-sizing-${name}: renamed entry did not render under the new key"
      else if lib.hasInfix "### Old guidance" renamedRuleText
      then throw "delegate-sizing-${name}: renamed entry still rendered under the old key"
      else if renamedWarnings != ["ai.programs.delegate-sizing.whenToDelegate.Old guidance has been renamed to ai.programs.delegate-sizing.whenToDelegate.New guidance; update the attribute name."]
      then throw "delegate-sizing-${name}: rename did not produce exactly one warning"
      else if !(warningDeliveryContract "collision" collisionWarnings collisionWarning)
      then false
      else if !(warningDeliveryContract "rename" packageRenamed packageRenameWarning)
      then false
      else true;
  in {
    "module-delegate-sizing-${name}-content" = mkTest "delegate-sizing-${name}-content" (
      lib.hasInfix "codex exec --model <slug> --config 'model_reasoning_effort=\"<level>\"' --json --output-last-message <out>.md - < <prompt-file>" claude
      && lib.hasInfix "## manual-only external delegate sizing\n" claude
      && lib.hasInfix "### kiro\n" claude
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
      && lib.hasInfix "/bin/claude-usage`" claude
      && lib.hasInfix "/bin/codex-usage`" codex
    );
    "module-delegate-sizing-${name}-external-enable" = mkTest "delegate-sizing-${name}-external-enable" (
      !(builtins.tryEval invalidChecked).success
      && lib.any
      (item: lib.hasInfix "ai.claude.programs.delegate-sizing.extraRuntimes includes `kiro`, but ai.kiro.enable is false" item.message)
      failed
      && lib.all (item: item.assertion) manualDisabled.config.assertions
      && lib.hasInfix "### kiro\n" (readSkill manualDisabled "claude")
      && lib.all (item: item.assertion) manualOverlap.config.assertions
      && readSkill manualOverlap "claude" == readSkill manualDisabled "claude"
    );
    "module-delegate-sizing-${name}-options" = mkTest "delegate-sizing-${name}-options" (
      let
        portable = optionTree result ["ai" "programs" "delegate-sizing"];
        perRuntime = optionTree result ["ai" "claude" "programs" "delegate-sizing"];
      in
        portable ? enable
        && portable ? whenToDelegate
        && !(portable ? extraRuntimes)
        && !(portable ? manualExternalDelegates)
        && !(portable ? settings)
        && perRuntime ? extraRuntimes
        && perRuntime ? manualExternalDelegates
        && perRuntime.settings ? launch
        && !(result.options.ai.kimchi.programs ? delegate-sizing)
        && !(result.options.ai.copilot.programs ? delegate-sizing)
    );
    "module-delegate-sizing-${name}-overrides" = mkTest "delegate-sizing-${name}-overrides" (
      lib.hasInfix "CUSTOM CLAUDE DELEGATION" customizedClaude
      && lib.hasInfix "CUSTOM CODEX LAUNCH" customizedClaude
      && !(lib.hasInfix "#### claude usage" customizedClaude)
      && !(lib.hasInfix "api.anthropic.com/api/oauth/usage" customizedClaude)
      && !(lib.hasInfix "maxEffortLevel" customizedClaude)
      && !(lib.hasInfix "kiro-cli chat --no-interactive" customizedClaude)
      && !(lib.hasInfix "_kiro/config/template" customizedClaude)
      && !(disabled.config.ai.codex.skills ? delegate-sizing)
      && !(disabled.config.ai.codex.rules ? delegate-sizing-router)
      && disabled.config.ai.claude.skills ? delegate-sizing
      && !(result.config.ai.skills ? delegate-sizing)
      && !(result.config.ai.rules ? delegate-sizing-router)
    );
    "module-delegate-sizing-${name}-stub" = mkTest "delegate-sizing-${name}-stub" (
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
      && lib.all (runtime: result.config.ai.${runtime}.rules.delegate-sizing-router.text == stub) runtimes
    );
    "module-delegate-sizing-${name}-when-to-delegate" = mkTest "delegate-sizing-${name}-when-to-delegate" (
      ruleText noEntries
      == builtins.readFile ../fragments/skill-routing.md
      && lib.hasInfix "### Consumer\n\nDelegate when the task is independently verifiable." (ruleText consumerEntry)
      && !(lib.hasInfix "### Preset" (ruleText disabledPreset))
      && lib.hasInfix "### Preset\n\nDelegate a preset task." (ruleText enabledPreset)
      && lib.all
      (preset: let
        declaredSource = shippedPresets.${preset}.source;
        expectedSource = shippedPresetSource preset;
        text = ruleText enabledShippedPresets.${preset};
      in
        assert lib.assertMsg (declaredSource == expectedSource)
        "delegate-sizing-${name}: preset `${preset}` source must match its name-derived fragment path";
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
    "module-delegate-sizing-${name}-when-to-delegate-preset-constructor" = mkTest "delegate-sizing-${name}-when-to-delegate-preset-constructor" presetConstructorContract;
    "module-delegate-sizing-${name}-when-to-delegate-protection" = mkTest "delegate-sizing-${name}-when-to-delegate-protection" protectionContract;
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
