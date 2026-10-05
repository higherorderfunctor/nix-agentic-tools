# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode sembleignore
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) aiStubs claudeSettings evalDevenv evalHm harnessNames hmLib markdownInput mkTest;
  inherit (import ../../packages/chatgpt-codex/checks/helpers.nix {inherit lib pkgs harness;}) hmCodexSettings withHmDaemonDefault;
  # Runtimes whose app record supports the normalized settings pool. Kiro is
  # excluded: it persists effort only per model, so it declares no
  # `ai.kiro.settings` (packages/kiro-cli/checks: kiro-settings-pool-excluded).
  settingsHarnessNames = lib.remove "kiro" harnessNames;
in {
  checks = {
    # ── Structural gate: every enabled runtime installs SOMETHING ──
    #
    # This is the test that would have caught `claude`. Installation used to be
    # a per-factory `home.packages` / `packages` write with no shared
    # requirement, and claude's was missing from BOTH backends, visible on
    # devenv as `claude` silently resolving to whatever the developer happened
    # to have installed user-globally.
    #
    # `lib/ai/app/mkBackendTransform.nix` now owns installation and defaults to
    # installing `cfg.package`, so saying nothing installs the plain package
    # rather than nothing. This table pins the delivery CHANNEL per runtime per
    # backend, which is the half a default cannot enforce: whether each one
    # installs a wrapper or the bare package.
    module-every-runtime-installs-package = mkTest "every-runtime-installs-package" (
      let
        # The SHAPE of each runtime's installed derivation per backend, not merely
        # that something was installed. `packages != []` alone is not enough: a
        # misspelled or dropped `installPackage` key falls through to the
        # transform's `cfg.package` default and installs the runtime's BARE
        # binary — no flag injection, no baked environment, no `secretEnv` — while
        # a count-only assertion still passes. Before the seam existed a wrong key
        # name was a Nix eval error inside `config`; now it is a silent
        # substitution, so the shape is what has to be pinned. The count pins the
        # other direction: a second install path to one `bin/<exe>` makes
        # buildEnv fail activation with a conflicting-subpath error.
        #
        # Every harness wraps on devenv because `gitSshConfigWorkaround` defaults
        # on and contributes `GIT_SSH_COMMAND`. Home Manager wraps only when a
        # launcher has something to inject, which a bare `enable = true` gives
        # none of them: kimchi's `region` and `telemetry.enabled` reach its
        # global config.json on Home Manager, not the launcher environment.
        # `claude` wraps only for `ai.extraSystemPrompt` (its env rides
        # `.claude/settings.json`, never process env), so without one it installs
        # `cfg.package` on both backends and MUST NOT gain a `-wrapped` suffix.
        shapes = {
          devenv = {
            claude = "bare";
            codex = "wrapped";
            copilot = "wrapped";
            kimchi = "wrapped";
            kiro = "wrapped";
          };
          hm = {
            claude = "bare";
            codex = "bare";
            copilot = "bare";
            kimchi = "bare";
            kiro = "bare";
          };
        };
        installedBy = {
          devenv = name: (evalDevenv {ai.${name}.enable = true;}).config.packages;
          hm = name: (evalHm {ai.${name}.enable = true;}).config.home.packages;
        };
        # `.name`, NOT `baseNameOf (toString drv)`: coercing a derivation to a string
        # forces its `drvPath` and instantiates every runtime's package, which
        # turns this eval-only check into a multi-minute realization. The name
        # attribute carries the same `-wrapped` signal for free.
        drvName = drv: drv.name or "";
        backendFailures = backend:
          lib.concatMap (
            name: let
              installed = installedBy.${backend} name;
              ok =
                builtins.length installed
                == 1
                && lib.hasSuffix "-wrapped" (drvName (builtins.head installed))
                == (shapes.${backend}.${name} == "wrapped");
            in
              lib.optional (!ok) "${name}/${backend}"
          )
          (builtins.attrNames shapes.${backend});
        failures = backendFailures "devenv" ++ backendFailures "hm";
      in
        # `mkTest` throws a bare `FAIL: <name>`, which would name neither the
        # runtime nor the backend across ten assertions. Trace the offenders first.
        if failures == []
        then true
        else
          builtins.trace
          "every-runtime-installs-package: wrong install channel or shape for ${builtins.concatStringsSep ", " failures}"
          false
    );

    # The option-presence gate in `lib/ai/mkSkillPackageModule.nix` is what lets a
    # consumer import a skill package WITHOUT importing all five runtime modules.
    #
    # Read how this test fails, because it is not the assertion below. Writing an
    # undeclared option is an EVALUATION error, so deleting the gate does not make
    # the boolean false — it aborts the evaluation with "The option `ai.codex'
    # does not exist" (measured). The assertion only confirms the write landed on
    # the one runtime that IS declared; the gate's coverage comes from the
    # evaluation completing at all.
    #
    # Declaring exactly one runtime is what creates that sensitivity, and it is
    # why this cannot be folded into the full-tree tests: `evalHm`/`evalDevenv`
    # import every runtime, so every option exists there and an ungated write
    # would evaluate cleanly and pass unnoticed.
    module-skill-package-gates-on-option-presence = mkTest "skill-package-gates-on-option-presence" (
      let
        onlyClaude = lib.evalModules {
          specialArgs = {
            lib = hmLib;
            pkgs = pkgs // {ai = aiStubs;};
          };
          modules = [
            {
              options.ai.claude = {
                rules = lib.mkOption {
                  type = lib.types.attrsOf lib.types.attrs;
                  default = {};
                };
                skills = lib.mkOption {
                  type = lib.types.attrsOf lib.types.path;
                  default = {};
                };
              };
            }
            (import ../../lib/ai/mkSkillPackageModule.nix {
              name = "probe-package";
              enableDescription = "presence-gate probe";
              rules = _: {probe-rule.text = "Probe guidance.";};
              skills = _: {probe-skill = ../fixtures;};
            })
            {ai.programs.probe-package.enable = true;}
          ];
        };
      in
        onlyClaude.config.ai.claude.skills ? probe-skill
        && onlyClaude.config.ai.claude.rules ? probe-rule
    );

    module-ai-git-ssh-default-follows-harnesses = mkTest "ai-git-ssh-default-follows-harnesses" (
      let
        # devenv has no `programs.git`, so the workaround travels the INTERNAL
        # channel (`ai._sandboxSafeSshCommand`) and each factory merges it into
        # its launcher wrapper. It is deliberately neither a project-shell write
        # (which reached the developer's own git) nor a hidden contribution into
        # the consumer-facing `ai.<cli>.environmentVariables` pool. Claude has no
        # wrapper and uses settings.env.
        devenvChannel = name: let
          cfg = (evalDevenv (lib.setAttrByPath ["ai" name "enable"] true)).config;
        in
          if name == "claude"
          then cfg.ai.claude.native.settings.env.GIT_SSH_COMMAND
          else cfg.ai._sandboxSafeSshCommand;
        commands =
          lib.concatMap (name: [
              (evalHm (lib.setAttrByPath ["ai" name "enable"] true))
          .config
          .programs
          .git
          .settings
          .core
          .sshCommand
              (devenvChannel name)
            ])
          harnessNames;
        disabledHm = (evalHm {}).config;
        disabledDevenv = (evalDevenv {}).config;
        optedOutHm =
          (evalHm {
            ai.codex.enable = true;
            ai.gitSshConfigWorkaround = false;
          }).config;
        optedOutDevenv =
          (evalDevenv {
            ai.codex.enable = true;
            ai.gitSshConfigWorkaround = false;
          }).config;
        overriddenHm =
          (evalHm {
            ai.codex.enable = true;
            programs.git.settings.core.sshCommand = "custom-ssh";
          }).config;
        # REGRESSION GUARD: a consumer setting the shared pool key the module
        # also contributes must NOT be a collision error. It was, briefly —
        # the module wrote into `ai.<cli>.environmentVariables`, which is
        # compared by key presence and cannot see `mkDefault`.
        sharedPoolCollision =
          (evalDevenv {
            ai.codex.enable = true;
            ai.environmentVariables.GIT_SSH_COMMAND = "consumer-ssh";
          }).config;
      in
        builtins.all (lib.hasSuffix "/bin/ai-sandbox-safe-ssh") commands
        && !(disabledHm.programs.git.settings ? core)
        && disabledDevenv.ai._sandboxSafeSshCommand == null
        && !(optedOutHm.programs.git.settings ? core)
        && optedOutDevenv.ai._sandboxSafeSshCommand == null
        && overriddenHm.programs.git.settings.core.sshCommand == "custom-ssh"
        && builtins.all (a: a.assertion) sharedPoolCollision.assertions
    );

    module-ai-git-ssh-wrapper-is-noninteractive = let
      command = (evalDevenv {ai.codex.enable = true;}).config.ai._sandboxSafeSshCommand;
      sshConfig = pkgs.writeText "sandbox-ssh-config" ''
        Host *
          BatchMode no
      '';
    in
      pkgs.runCommand "module-test-ai-git-ssh-wrapper-is-noninteractive" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :

        mkdir -p home/.ssh
        ln -s ${sshConfig} home/.ssh/config
        HOME="$PWD/home" ${command} -G github.com > resolved
        ${pkgs.gnugrep}/bin/grep -Fqx 'batchmode yes' resolved || {
          echo "FAIL: expected OpenSSH to resolve 'batchmode yes'; got:" >&2
          ${pkgs.gnugrep}/bin/grep -F 'batchmode ' resolved >&2 || :
          exit 1
        }
        touch "$out"
      '';

    module-aggregate-reasoning-effort-hm-devenv-parity = mkTest "aggregate-reasoning-effort-hm-devenv-parity" (
      let
        config.ai = {
          claude.enable = true;
          codex.enable = true;
          settings.reasoningEffort = "xhigh";
        };
        hm = evalHm config;
        devenv = evalDevenv config;
      in
        ((claudeSettings hm).effortLevel or null)
        == "xhigh"
        && ((hmCodexSettings hm).model_reasoning_effort or null) == "xhigh"
        && ((claudeSettings devenv).effortLevel or null) == "xhigh"
        && (devenv.config.ai.codex.files.".codex/config.toml".content.value.model_reasoning_effort or null) == "xhigh"
    );

    module-runtime-reasoning-effort-overrides-root-only-for-that-runtime = mkTest "runtime-reasoning-effort-overrides-root-only-for-that-runtime" (
      let
        config.ai = {
          claude = {
            enable = true;
            settings.reasoningEffort = "low";
          };
          codex.enable = true;
          settings.reasoningEffort = "high";
        };
        hm = evalHm config;
        devenv = evalDevenv config;
      in
        ((claudeSettings hm).effortLevel or null)
        == "low"
        && ((hmCodexSettings hm).model_reasoning_effort or null) == "high"
        && ((claudeSettings devenv).effortLevel or null) == "low"
        && (devenv.config.ai.codex.files.".codex/config.toml".content.value.model_reasoning_effort or null) == "high"
    );

    module-runtime-settings-exist-for-capable-harnesses = mkTest "runtime-settings-exist-for-capable-harnesses" (
      let
        config.ai = lib.genAttrs settingsHarnessNames (_: {
          settings.reasoningEffort = "low";
        });
        hm = evalHm config;
        devenv = evalDevenv config;
      in
        lib.all (runtime: hm.config.ai.${runtime}.settings.reasoningEffort == "low") settingsHarnessNames
        && lib.all (runtime: devenv.config.ai.${runtime}.settings.reasoningEffort == "low") settingsHarnessNames
    );

    module-runtime-settings-reject-native-keys = mkTest "runtime-settings-reject-native-keys" (
      let
        rejects = evaluator: let
          attempt = builtins.tryEval (let
            result = evaluator {
              ai.claude.settings.effortLevel = "high";
            };
          in
            builtins.deepSeq result.config.ai.claude.settings true);
        in
          !attempt.success;
      in
        rejects evalHm && rejects evalDevenv
    );

    module-aggregate-reasoning-effort-native-overrides-win = mkTest "aggregate-reasoning-effort-native-overrides-win" (
      let
        config.ai = {
          claude = {
            enable = true;
            native.settings.effortLevel = "medium";
          };
          codex = {
            enable = true;
            native.settings.model_reasoning_effort = null;
          };
          settings.reasoningEffort = "high";
        };
        hm = evalHm config;
        devenv = evalDevenv config;
      in
        ((claudeSettings hm).effortLevel or null)
        == "medium"
        && hmCodexSettings hm == withHmDaemonDefault {model = "gpt-6-astra";}
        && ((claudeSettings devenv).effortLevel or null) == "medium"
        && devenv.config.ai.codex.files.".codex/config.toml".content.value == {model = "gpt-6-astra";}
    );

    module-shared-hooks-reject-non-portable-event = mkTest "shared-hooks-reject-non-portable-event" (!(builtins.tryEval (
      builtins.deepSeq
      (evalHm {
        ai.hooks.ConfigChange = [{hooks = [{command = "true";}];}];
      }).config.ai.hooks
      true
    )).success);

    module-all-four-enabled = mkTest "all-four-enabled" (
      let
        config = {
          ai = {
            claude.enable = true;
            codex.enable = true;
            copilot.enable = true;
            kiro.enable = true;
          };
        };
        hm = evalHm config;
        devenv = evalDevenv config;
      in
        hm.config.ai.claude.enable
        && hm.config.ai.codex.enable
        && hm.config.ai.copilot.enable
        && hm.config.ai.kiro.enable
        && devenv.config.ai.claude.enable
        && devenv.config.ai.codex.enable
        && devenv.config.ai.copilot.enable
        && devenv.config.ai.kiro.enable
    );

    # Skill packages consume the generic program factory. Each package's
    # portable option tree is exact, and shared declarations produce identical
    # HM/devenv root and runtime option trees within its capability set,
    # including nested runtime-only settings.
    # `gitPreset` deliberately stays out of this tree as a top-level companion
    # because it configures Git, not a runtime. Both backends import one
    # declaration of it (packages/stacked-workflows/modules/options.nix).
    module-skill-packages-program-option-parity = mkTest "skill-packages-program-option-parity" (
      let
        shape = declarations:
          lib.mapAttrs (_: option:
            if lib.isOption option
            then option.type.description
            else shape option)
          (builtins.removeAttrs declarations ["_module"]);
        programOptions = evaluated: package: evaluated.options.ai.programs.${package};
        optionShape = evaluated: package: shape (programOptions evaluated package);
        runtimeShape = evaluated: package: runtime:
          shape (programOptions evaluated package).runtimes.${runtime};
        hm = evalHm {};
        devenv = evalDevenv {};
        gitPresetValues = evaluated:
          evaluated.options.stacked-workflows.gitPreset.type.functor.payload.values;
        programParity = package: expectedRootShape: runtimes:
          builtins.removeAttrs (optionShape hm package) ["runtimes"]
          == expectedRootShape
          && builtins.attrNames (programOptions hm package).runtimes == runtimes
          && optionShape hm package
          == optionShape devenv package
          && lib.all
          (runtime:
            runtimeShape hm package runtime
            == runtimeShape devenv package runtime)
          runtimes;
      in
        programParity "delegate-routing" {
          enable = "boolean";
          families = "attribute set of attribute set of (submodule)";
          reminder = "submodule";
          routing = "attribute set of (submodule)";
          workflows = "attribute set of (submodule)";
        } ["claude" "codex" "kimchi" "kiro"]
        && programParity "peer-communication" {enable = "boolean";} harnessNames
        && programParity "stacked-workflows" {enable = "boolean";} harnessNames
        && hm.options.stacked-workflows ? gitPreset
        && devenv.options.stacked-workflows ? gitPreset
        && gitPresetValues hm == ["full" "minimal" "none"]
        && gitPresetValues hm == gitPresetValues devenv
    );

    module-program-whole-record-priorities = mkTest "program-whole-record-priorities" (
      lib.all
      (evaluate:
        lib.all
        (package:
          lib.all
          (priority: let
            evaluated = evaluate {
              ai = {
                claude.enable = true;
                codex.enable = true;
                programs.${package} = lib.mkMerge [
                  (priority {enable = true;})
                  {runtimes.claude.enable = false;}
                ];
              };
            };
            skillName =
              if package == "stacked-workflows"
              then "stack-plan"
              else package;
            contributes = runtime:
              if package == "semble"
              then evaluated.config.ai.${runtime}.mcpServers ? semble
              else evaluated.config.ai.${runtime}.skills ? ${skillName};
          in
            assert lib.assertMsg (!(contributes "claude") && contributes "codex")
            "${package}: portable=${builtins.toJSON evaluated.config.ai.programs.${package}.enable}, claude=${builtins.toJSON (contributes "claude")}, codex=${builtins.toJSON (contributes "codex")}"; true)
          [lib.mkDefault lib.mkForce])
        ["delegate-routing" "peer-communication" "semble" "stacked-workflows"])
      [evalHm evalDevenv]
    );

    # ── Priority-ordered rule triggers ─────────────────────────────
    module-rule-inclusion-priority-falls-back-per-runtime = mkTest "rule-inclusion-priority-falls-back-per-runtime" (
      let
        evaluated = evalDevenv {
          ai = {
            claude.enable = true;
            copilot.enable = true;
            kiro.enable = true;
            rules.priority = {
              description = "Load when the task concerns source code";
              inclusion = ["auto" "fileMatch"];
              matcher = ["src/**"];
              text = "PRIORITY-RULE.";
            };
          };
        };
        claude = (markdownInput evaluated ".claude/rules/priority.md").text;
        copilot = (markdownInput evaluated ".github/instructions/priority.instructions.md").text;
        kiro = (markdownInput evaluated ".kiro/steering/priority.md").text;
      in
        lib.hasInfix "paths:\n  - \"src/**\"" claude
        && lib.hasInfix ''applyTo: "src/**"'' copilot
        && lib.hasInfix ''inclusion: "auto"'' kiro
        && lib.hasInfix ''description: "Load when the task concerns source code"'' kiro
        && !(lib.hasInfix "fileMatchPattern:" kiro)
    );

    module-rule-inclusion-unsupported-runtime-fails = mkTest "rule-inclusion-unsupported-runtime-fails" (
      let
        unsupportedAttempt = builtins.tryEval (let
          evaluated = evalDevenv {
            ai = {
              claude.enable = true;
              rules.manual = {
                inclusion = ["manual"];
                text = "MANUAL-RULE.";
              };
            };
          };
        in
          builtins.deepSeq (markdownInput evaluated ".claude/rules/manual.md").text true);
      in
        !unsupportedAttempt.success
    );

    module-rule-inclusion-auto-requires-description = mkTest "rule-inclusion-auto-requires-description" (
      let
        attempt = builtins.tryEval (let
          evaluated = evalDevenv {
            ai = {
              kiro.enable = true;
              rules.semantic = {
                inclusion = ["auto"];
                text = "SEMANTIC-RULE.";
              };
            };
          };
        in
          builtins.deepSeq (markdownInput evaluated ".kiro/steering/semantic.md").text true);
      in
        !attempt.success
    );

    module-rule-inclusion-codex-auto-needs-references = mkTest "rule-inclusion-codex-auto-needs-references" (
      let
        withReferences = evalDevenv {
          ai = {
            codex.enable = true;
            rules.semantic = {
              description = "Load when semantic guidance applies";
              inclusion = ["auto"];
              references = ["docs/semantic.md"];
              text = "SEMANTIC-RULE-BODY.";
            };
          };
        };
        agentsMd = (markdownInput withReferences "AGENTS.md").text;
        withoutReferences = builtins.tryEval (let
          evaluated = evalDevenv {
            ai = {
              codex.enable = true;
              rules.semantic = {
                description = "Load when semantic guidance applies";
                inclusion = ["auto"];
                text = "SEMANTIC-RULE-BODY.";
              };
            };
          };
        in
          builtins.deepSeq (markdownInput evaluated "AGENTS.md").text true);
      in
        lib.hasInfix "## Rule index" agentsMd
        && withReferences.config.ai.internal.agentsMd."AGENTS.md".hasOnDemandIndex
        && lib.hasInfix "Trigger: `auto`" agentsMd
        && lib.hasInfix "Description: Load when semantic guidance applies" agentsMd
        && lib.hasInfix "[`docs/semantic.md`](docs/semantic.md)" agentsMd
        && !(lib.hasInfix "SEMANTIC-RULE-BODY." agentsMd)
        && !withoutReferences.success
    );

    module-rule-inclusion-defaults-preserve-rendering = mkTest "rule-inclusion-defaults-preserve-rendering" (
      let
        config = {
          ai = {
            claude.enable = true;
            codex.enable = true;
            copilot.enable = true;
            kiro.enable = true;
            rules = {
              always.text = "DEFAULT-ALWAYS.";
              scoped = {
                matcher = ["src/**"];
                text = "DEFAULT-SCOPED.";
              };
            };
          };
        };
        evaluated = evalDevenv config;
        claudeAlways = (markdownInput evaluated ".claude/rules/always.md").text;
        claudeScoped = (markdownInput evaluated ".claude/rules/scoped.md").text;
        copilotAlways = (markdownInput evaluated ".github/instructions/always.instructions.md").text;
        copilotScoped = (markdownInput evaluated ".github/instructions/scoped.instructions.md").text;
        kiroScoped = (markdownInput evaluated ".kiro/steering/scoped.md").text;
        agentsMd = (markdownInput evaluated "AGENTS.md").text;
      in
        evaluated.config.ai.rules.always.inclusion
        == ["always"]
        && evaluated.config.ai.rules.scoped.inclusion == ["fileMatch"]
        && claudeAlways == "DEFAULT-ALWAYS."
        && lib.hasInfix "paths:\n  - \"src/**\"" claudeScoped
        && lib.hasInfix ''applyTo: "**"'' copilotAlways
        && lib.hasInfix ''applyTo: "src/**"'' copilotScoped
        && lib.hasInfix ''inclusion: "fileMatch"'' kiroScoped
        && lib.hasInfix "fileMatchPattern: \"src/**\"" kiroScoped
        && lib.hasInfix "<!-- rule: always -->" agentsMd
        && lib.hasInfix "DEFAULT-ALWAYS." agentsMd
        && lib.hasInfix "_Apply this guidance only when working with files matching: `src/**`_" agentsMd
        && lib.hasInfix "DEFAULT-SCOPED." agentsMd
    );

    # ── Normalized keyed-pool suppression types ────────────────────
    # The merge contract itself is covered once per pool in factory-eval.nix.
    # This full-tree check pins the other half: nullable pools accept tombstones,
    # while rules use their entry-local enable flag at every supported scope.
    module-ai-pool-null-types-hm-devenv = mkTest "ai-pool-null-types-hm-devenv" (
      let
        config.ai = {
          agents.removed = null;
          environmentVariables.removed = null;
          lspServers.removed = null;
          mcpServers.removed = null;
          rules.removed.enable = false;
          skills.removed = null;

          claude = {
            agents.removed = null;
            lspServers.removed = null;
            mcpServers.removed = null;
            rules.removed.enable = false;
            skills.removed = null;
          };
          codex = {
            agents.removed = null;
            environmentVariables.removed = null;
            mcpServers.removed = null;
            rules.removed.enable = false;
            skills.removed = null;
          };
          copilot = {
            agents.removed = null;
            environmentVariables.removed = null;
            lspServers.removed = null;
            mcpServers.removed = null;
            rules.removed.enable = false;
            skills.removed = null;
          };
          kimchi.environmentVariables.removed = null;
          kiro = {
            environmentVariables.removed = null;
            lspServers.removed = null;
            mcpServers.removed = null;
            rules.removed.enable = false;
            skills.removed = null;
          };
        };
        keepsNulls = evaluated:
          evaluated.config.ai.agents.removed
          == null
          && evaluated.config.ai.claude.lspServers.removed == null
          && evaluated.config.ai.codex.environmentVariables.removed == null
          && evaluated.config.ai.copilot.mcpServers.removed == null
          && evaluated.config.ai.kimchi.environmentVariables.removed == null
          && evaluated.config.ai.kiro.skills.removed == null
          && !evaluated.config.ai.rules.removed.enable
          && !evaluated.config.ai.claude.rules.removed.enable
          && !evaluated.config.ai.codex.rules.removed.enable
          && !evaluated.config.ai.copilot.rules.removed.enable
          && !evaluated.config.ai.kiro.rules.removed.enable;
      in
        keepsNulls (evalHm config) && keepsNulls (evalDevenv config)
    );
  };
}
