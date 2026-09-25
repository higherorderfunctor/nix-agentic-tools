# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode sembleignore
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) aiStubs evalDevenv evalHm harnessNames hmLib mkTest;
  inherit (import ../../packages/chatgpt-codex/checks/helpers.nix {inherit lib pkgs harness;}) hmCodexSettings;
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
    # requirement, and claude's was missing from BOTH backends — invisible on
    # Home Manager because upstream's `programs.claude-code` installs the
    # package anyway, and visible on devenv only as `claude` silently resolving
    # to whatever the developer happened to have installed user-globally.
    #
    # `lib/ai/app/mkBackendTransform.nix` now owns installation and defaults to
    # installing `cfg.package`, so saying nothing installs the plain package
    # rather than nothing. This table pins the delivery CHANNEL per runtime per
    # backend, which is the half a default cannot enforce: it catches a factory
    # that opts out with `installPackage = null` for a reason that stops being
    # true.
    #
    # `claude` on Home Manager is the ONE deliberate empty `home.packages`. It
    # must not install there, or two paths to the same `bin/claude` land in one
    # profile and buildEnv fails activation with a conflicting-subpath error.
    # Its channel is `programs.claude-code.package`, asserted explicitly so the
    # exemption cannot silently widen into "claude installs nothing anywhere".
    module-every-runtime-installs-package = mkTest "every-runtime-installs-package" (
      let
        # The devenv-side SHAPE of each runtime's installed derivation, not merely
        # that something was installed. `packages != []` alone is not enough: a
        # misspelled or dropped `installPackage` key falls through to the
        # transform's `cfg.package` default and installs the runtime's BARE
        # binary — no flag injection, no baked environment, no `secretEnv` — while
        # a count-only assertion still passes. Before the seam existed a wrong key
        # name was a Nix eval error inside `config`; now it is a silent
        # substitution, so the shape is what has to be pinned.
        #
        # Every harness wraps on devenv because `gitSshConfigWorkaround` defaults
        # on and contributes `GIT_SSH_COMMAND`. `claude` is the exception at the
        # other end: it has no wrapper anywhere (its env rides
        # `.claude/settings.json`, never process env), so it installs `cfg.package`
        # and MUST NOT gain a `-wrapped` suffix.
        devenvShape = {
          claude = "bare";
          codex = "wrapped";
          copilot = "wrapped";
          kimchi = "wrapped";
          kiro = "wrapped";
        };
        runtimes = builtins.attrNames devenvShape;
        # `.name`, NOT `baseNameOf (toString drv)`: coercing a derivation to a string
        # forces its `drvPath` and instantiates every runtime's package, which
        # turns this eval-only check into a multi-minute realization. The name
        # attribute carries the same `-wrapped` signal for free.
        drvName = drv: drv.name or "";
        devenvFailures =
          builtins.concatMap (
            name: let
              installed = (evalDevenv {ai.${name}.enable = true;}).config.packages;
              wrapped = lib.hasSuffix "-wrapped" (drvName (builtins.head installed));
              ok =
                builtins.length installed
                == 1
                && (
                  if devenvShape.${name} == "wrapped"
                  then wrapped
                  else !wrapped
                );
            in
              lib.optional (!ok) "${name}/devenv"
          )
          runtimes;
        hmFailures =
          builtins.concatMap (
            name: let
              hm = evalHm {ai.${name}.enable = true;};
              claudeChannel = hm.config.programs.claude-code or {};
              ok =
                if name == "claude"
                # `programs.claude-code` is collapsed to `attrsOf anything` in this
                # harness, so read it defensively: without the `?` guard, a factory
                # that stopped setting `package` would throw an attribute error
                # rather than fail this assertion.
                then
                  (claudeChannel ? package)
                  && claudeChannel.package != null
                  && hm.config.home.packages == []
                else hm.config.home.packages != [];
            in
              lib.optional (!ok) "${name}/hm"
          )
          runtimes;
        failures = devenvFailures ++ hmFailures;
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
        # devenv has no `programs.git`, so the workaround travels each
        # runtime's INTERNAL channel (`ai.<cli>.internal._moduleEnvironmentVariables`)
        # and each factory merges it into its launcher wrapper. It is
        # deliberately neither a project-shell write (which reached the
        # developer's own git) nor a hidden contribution into the
        # consumer-facing `ai.<cli>.environmentVariables` pool. Claude has no
        # wrapper and uses settings.env.
        channel = cfg: name: cfg.ai.${name}.internal._moduleEnvironmentVariables.GIT_SSH_COMMAND or null;
        devenvChannel = name: let
          cfg = (evalDevenv (lib.setAttrByPath ["ai" name "enable"] true)).config;
        in
          if name == "claude"
          then cfg.ai.claude.native.settings.env.GIT_SSH_COMMAND
          else channel cfg name;
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
        && builtins.all (name: channel disabledDevenv name == null) harnessNames
        && !(optedOutHm.programs.git.settings ? core)
        && builtins.all (name: channel optedOutDevenv name == null) harnessNames
        && overriddenHm.programs.git.settings.core.sshCommand == "custom-ssh"
        && builtins.all (a: a.assertion) sharedPoolCollision.assertions
    );

    # `mkRuntime` is public, so the module-env channel must reach a runtime
    # outside the first-party registry too: it did when the SSH default was
    # one root value every transform read, and the per-runtime channel finds
    # runtimes in the option tree to keep it that way. Mutation-checked: a
    # registry-only `publish` turns this red.
    module-ai-module-env-reaches-downstream-runtime = mkTest "ai-module-env-reaches-downstream-runtime" (
      let
        factory = import ../../lib/testing/factory-harness.nix {inherit lib pkgs harness;};
        record = factory.ai.app.mkRuntime {
          inherit pkgs;
          name = "downstream";
          defaults.package = pkgs.hello;
          options._observedEnv = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = {};
            internal = true;
          };
          config = {moduleEnvironmentVariables, ...}: {
            ai.downstream._observedEnv = moduleEnvironmentVariables;
          };
        };
        evaluated = lib.evalModules {
          specialArgs = {inherit pkgs;};
          modules = [
            factory.ai.sharedOptions
            factory.devenvStubs
            (factory.ai.app.devenvTransform record)
            # The SSH default is gated on a REGISTRY harness being enabled
            # (`anyHarnessEnabled`), unchanged here; this stands in for one
            # without importing a whole runtime module.
            {
              options.ai.codex.enable = lib.mkEnableOption "registry harness stand-in";
              config.ai = {
                codex.enable = true;
                downstream.enable = true;
              };
            }
          ];
        };
      in
        lib.hasSuffix "/bin/ai-sandbox-safe-ssh" (evaluated.config.ai.downstream._observedEnv.GIT_SSH_COMMAND or "")
    );

    module-ai-git-ssh-wrapper-is-noninteractive = let
      command = (evalDevenv {ai.codex.enable = true;}).config.ai.codex.internal._moduleEnvironmentVariables.GIT_SSH_COMMAND;
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
        (hm.config.programs.claude-code.settings.effortLevel or null)
        == "xhigh"
        && ((hmCodexSettings hm).model_reasoning_effort or null) == "xhigh"
        && (devenv.config.files.".claude/settings.json".json.effortLevel or null) == "xhigh"
        && (devenv.config.files.".codex/config.toml".source.value.model_reasoning_effort or null) == "xhigh"
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
        (hm.config.programs.claude-code.settings.effortLevel or null)
        == "low"
        && ((hmCodexSettings hm).model_reasoning_effort or null) == "high"
        && (devenv.config.files.".claude/settings.json".json.effortLevel or null) == "low"
        && (devenv.config.files.".codex/config.toml".source.value.model_reasoning_effort or null) == "high"
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
        (hm.config.programs.claude-code.settings.effortLevel or null)
        == "medium"
        && hmCodexSettings hm == {model = "gpt-6-astra";}
        && (devenv.config.files.".claude/settings.json".json.effortLevel or null) == "medium"
        && devenv.config.files.".codex/config.toml".source.value == {model = "gpt-6-astra";}
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
    # `gitPreset` deliberately stays out of this tree as an HM-only top-level
    # companion because it configures machine-wide Git, not a runtime.
    module-skill-packages-program-option-parity = mkTest "skill-packages-program-option-parity" (
      let
        shape = declarations:
          lib.mapAttrs (_: option:
            if lib.isOption option
            then option.type.description
            else shape option)
          (builtins.removeAttrs declarations ["_module"]);
        optionShape = evaluated: path:
          shape ((lib.getAttrFromPath path evaluated.options).type.getSubOptions []);
        hm = evalHm {};
        devenv = evalDevenv {};
        programParity = package: expectedRootShape: runtimes:
          optionShape hm ["ai" "programs" package]
          == expectedRootShape
          && optionShape hm ["ai" "programs" package]
          == optionShape devenv ["ai" "programs" package]
          && lib.all
          (runtime:
            optionShape hm ["ai" runtime "programs" package]
            == optionShape devenv ["ai" runtime "programs" package])
          runtimes;
      in
        programParity "delegate-sizing" {
          enable = "boolean";
          whenToDelegate = "attribute set of (submodule)";
        } ["claude" "codex" "kiro"]
        && programParity "stacked-workflows" {enable = "boolean";} harnessNames
        && hm.options.stacked-workflows ? gitPreset
        && !(devenv.options ? stacked-workflows)
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
