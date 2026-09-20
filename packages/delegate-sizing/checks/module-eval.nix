# Exercise the generated files as delivered through both consumer backends.
{
  lib,
  harness,
  ...
}: let
  inherit (harness) evalDevenv evalHm mkTest;
  runtimes = ["claude" "codex" "kiro"];
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
  readSkill = result: runtime: builtins.readFile "${result.config.ai.${runtime}.skills.delegate-sizing}/SKILL.md";
  optionTree = result: path: (lib.getAttrFromPath path result.options).type.getSubOptions [];
  checkBackend = name: evaluate: let
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
      && !(lib.hasInfix "Astra (GPT-6)" kiro)
      && !(lib.hasInfix "Fable 5.1" kiro)
      && builtins.pathExists "${result.config.ai.claude.skills.delegate-sizing}/scripts/codex-usage.sh"
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
  };
in {
  checks = checkBackend "devenv" evalDevenv // checkBackend "hm" evalHm;
}
