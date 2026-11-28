# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode sembleignore
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) aiStubs checkRows claudeSettings evalDevenv evalHm harnessNames hmLib markdownInput mkTest rejectsChange setEnable;
  inherit (import ../../packages/chatgpt-codex/checks/helpers.nix {inherit lib pkgs harness;}) hmCodexSettings withHmDefaults;
  backends = {
    devenv = evalDevenv;
    hm = evalHm;
  };
  optionPaths = import ../../lib/ai/option-paths.nix {inherit lib pkgs;};
  # Runtimes whose record declares settings support.
  settingsHarnessNames = builtins.filter (name: (optionPaths.records.${name}.surfaceSupport.settings.backends or []) != []) harnessNames;
in {
  checks = {
    module-package-copilot-backend-gate = let
      devenv = evalDevenv {
        ai.copilot.enable = true;
        ai.programs.stacked-workflows.enable = true;
      };
      roots = devenv.config.ai.internal.roots;
      expectedSkills = roots.stacked-workflows-content.passthru.skills;
      # Read the named source instead of calling the router factory again.
      expectedRouter =
        "<!-- Fragment: packages/stacked-workflows/fragments/skill-routing.md -->\n\n"
        + builtins.readFile ../../packages/stacked-workflows/fragments/skill-routing.md;
      github = devenv.config.ai.copilot.github;
      poolWarnings = builtins.filter (lib.hasInfix "ai.copilot.github.") devenv.config.warnings;
    in
      mkTest "package-copilot-backend-gate" (checkRows "Copilot package backend gate" {
        "devenv Copilot receives the router body" =
          builtins.attrNames github.rules
          == ["stacked-workflows-router"]
          && github.rules.stacked-workflows-router.text == expectedRouter;
        "devenv Copilot receives the complete packaged skill set without warnings" =
          builtins.attrNames github.skills
          == ["stack-fix" "stack-plan" "stack-split" "stack-submit" "stack-summary" "stack-test"]
          && github.skills == expectedSkills
          && poolWarnings == [];
      });

    module-runtime-path-provenance-notice = let
      # Every runtime that ships a launcher; github.com Copilot has none.
      binaries = {
        claude = "claude";
        codex = "codex";
        kimchi = "kimchi";
        kiro = "kiro-cli";
      };
      fixtureFor = runtime: let
        package = pkgs.writeShellScriptBin binaries.${runtime} ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          exit 0
        '';
        configFor = package:
          lib.setAttrByPath (lib.init (optionPaths.launcher runtime "package"))
          ({inherit package;} // lib.optionalAttrs (runtime == "kiro") {useFhsSandbox = false;});
        evaluated = evalDevenv (lib.recursiveUpdate (setEnable runtime true) (configFor package));
        noticeLines = config: lib.filter (lib.hasInfix "/bin/ai-runtime-path-provenance-notice ") (lib.splitString "\n" config.enterShell);
        lines = noticeLines evaluated.config;
      in
        assert checkRows "runtime PATH-provenance notice" {
          "${runtime}: explicit null package suppresses the notice" =
            noticeLines (evalDevenv (lib.recursiveUpdate (setEnable runtime true) (configFor null))).config == [];
          "${runtime}: selected launcher emits exactly one notice" = builtins.length lines == 1;
        };
          pkgs.writeShellScript "rendered-${runtime}-path-notice" ''
            set -euETo pipefail
            shopt -s inherit_errexit 2>/dev/null || :
            ${lib.head lines}
          '';
    in
      assert checkRows "runtime PATH-provenance coverage" {
        "all launchers have an executable fixture" = builtins.attrNames binaries == lib.sort builtins.lessThan (lib.filter optionPaths.hasLauncher harnessNames);
        "disabled runtimes emit no notice" = !(lib.hasInfix "/bin/ai-runtime-path-provenance-notice " (evalDevenv {}).config.enterShell);
      };
        pkgs.runCommand "module-test-runtime-path-provenance-notice" {} ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          ${pkgs.python3}/bin/python3 ${./runtime-path-provenance-test.py} ${lib.escapeShellArgs (lib.concatLists (lib.mapAttrsToList (runtime: binary: [binary (fixtureFor runtime)]) binaries))}
          echo PASS > "$out"
        '';

    # ── Structural gate: default package installs ──
    #
    # This is the test that would have caught `claude`. Installation used to be
    # a per-factory `home.packages` / `packages` write with no shared
    # requirement, and claude's was missing from BOTH backends, visible on
    # devenv as `claude` silently resolving to whatever the developer happened
    # to have installed user-globally.
    #
    # `lib/ai/app/mkBackendTransform.nix` now owns installation and defaults to
    # installing the selected launcher package, so saying nothing installs it
    # rather than nothing. This table pins the delivery CHANNEL per runtime per
    # backend, which is the half a default cannot enforce: whether each one
    # installs a wrapper or the bare package.
    module-every-runtime-installs-package = mkTest "every-runtime-installs-package" (
      let
        # The SHAPE of each runtime's installed derivation per backend, not merely
        # that something was installed. `packages != []` alone is not enough: a
        # misspelled or dropped `installPackage` key falls through to the
        # transform's plain-package default and installs the runtime's BARE
        # binary — no flag injection, no baked environment, no `secretEnv` — while
        # a count-only assertion still passes. Before the seam existed a wrong key
        # name was a Nix eval error inside `config`; now it is a silent
        # substitution, so the shape is what has to be pinned. The count pins the
        # other direction: a second install path to one `bin/<exe>` makes
        # buildEnv fail activation with a conflicting-subpath error.
        #
        # Each wrapper-capable runtime wraps on devenv because
        # `gitSshConfigWorkaround` defaults on and contributes `GIT_SSH_COMMAND`.
        # Codex and Kiro have their own install and launcher checks. Kimchi
        # also always wraps on Home Manager for its launch preflight.
        # `claude` has no wrapper anywhere (its env rides
        # `.claude/settings.json`, never process env), so it installs `cfg.package`
        # on both backends and MUST NOT gain a `-wrapped` suffix.
        shapes = {
          claude = "bare";
          kimchi = "wrapped";
        };
        installedBy = {
          devenv = name: (evalDevenv (setEnable name true)).config.packages;
          hm = name: (evalHm (setEnable name true)).config.home.packages;
        };
        # `.name`, NOT `baseNameOf (toString drv)`: coercing a derivation to a string
        # forces its `drvPath` and instantiates every runtime's package, which
        # turns this eval-only check into a multi-minute realization. The name
        # attribute carries the same `-wrapped` signal for free.
        drvName = drv: drv.name or "";
        rows = lib.concatMapAttrs (backend: install:
          lib.mapAttrs' (name: shape: let
            installed = install name;
          in
            lib.nameValuePair "${backend}/${name} installs exactly one ${shape} package" (
              builtins.length installed
              == 1
              && lib.hasSuffix "-wrapped" (drvName (builtins.head installed)) == (shape == "wrapped")
            ))
          shapes)
        installedBy;
      in
        checkRows "runtime install channel and shape" rows
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
              backend = "hm";
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
        # Home Manager covers membership in the shared enable predicate; the
        # executable wrapper check covers the one devenv internal channel.
        # Claude has no wrapper, so additionally read its settings.env delivery.
        claudeDevenv = (evalDevenv (setEnable "claude" true)).config;
        isSandboxSafeSsh = lib.hasSuffix "/bin/ai-sandbox-safe-ssh";
        hmRows = builtins.listToAttrs (map (runtime: let
          cfg = (evalHm (setEnable runtime true)).config;
        in
          lib.nameValuePair "hm/${runtime}: enabling the runtime selects sandbox-safe SSH"
          (isSandboxSafeSsh cfg.programs.git.settings.core.sshCommand))
        harnessNames);
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
        checkRows "sandbox-safe SSH selection" (hmRows
          // {
            "devenv with no enabled runtime leaves the SSH channel unset" = disabledDevenv.ai._sandboxSafeSshCommand == null;
            "devenv with the workaround opted out leaves the SSH channel unset" = optedOutDevenv.ai._sandboxSafeSshCommand == null;
            "devenv workaround does not collide with the consumer's shared SSH key" =
              sharedPoolCollision.ai.codex.normalized.environmentVariables.GIT_SSH_COMMAND
              == "consumer-ssh"
              && builtins.all (a: a.assertion) sharedPoolCollision.assertions;
            "devenv/claude: enabling the runtime selects sandbox-safe SSH" = isSandboxSafeSsh claudeDevenv.ai.claude.native.settings.env.GIT_SSH_COMMAND;
            "hm preserves the consumer's explicit SSH command" = overriddenHm.programs.git.settings.core.sshCommand == "custom-ssh";
            "hm with the workaround opted out does not write core.sshCommand" = !(optedOutHm.programs.git.settings ? core);
          })
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

    module-reasoning-effort-precedence = mkTest "reasoning-effort-precedence" (
      let
        evaluate = evaluateBackend: ai:
          evaluateBackend {
            ai =
              {
                claude.enable = true;
                codex.enable = true;
              }
              // ai;
          };
        readCodex = {
          # Read the rendered settings entry, not the portable declaration.
          devenv = result: result.config.ai.codex.files.".codex/config.toml".content.value;
          hm = hmCodexSettings;
        };
        rows =
          lib.concatMapAttrs (backend: evaluateBackend: let
            eval = evaluate evaluateBackend;
            inherited = eval {settings.reasoningEffort = "xhigh";};
            local = eval {
              claude = {
                enable = true;
                settings.reasoningEffort = "low";
              };
              settings.reasoningEffort = "high";
            };
            native = eval {
              codex = {
                enable = true;
                native.settings.model_reasoning_effort = null;
              };
              settings.reasoningEffort = "high";
            };
            codexEffort = result: (readCodex.${backend} result).model_reasoning_effort or null;
          in {
            "${backend}/Claude inherits root effort under the native key" = ((claudeSettings inherited).effortLevel or null) == "xhigh";
            "${backend}/Claude runtime effort wins over root effort" = ((claudeSettings local).effortLevel or null) == "low";
            "${backend}/Codex inherits root effort under the native key" = codexEffort inherited == "xhigh";
            "${backend}/Codex is not affected by Claude's runtime effort" = codexEffort local == "high";
            "${backend}/Codex native null suppresses portable effort" =
              if backend == "hm"
              then hmCodexSettings native == withHmDefaults {}
              else !(native.config.ai.codex.files ? ".codex/config.toml");
          })
          backends;
      in
        checkRows "reasoning effort precedence" rows
    );

    module-runtime-settings-exist-for-capable-harnesses = mkTest "runtime-settings-exist-for-capable-harnesses" (
      checkRows "settings-capable runtimes" {
        "Claude, Codex, and Kimchi declare shared settings support" = settingsHarnessNames == ["claude" "codex" "kimchi"];
      }
    );

    module-runtime-settings-reject-native-keys = mkTest "runtime-settings-reject-native-keys" (
      checkRows "portable runtime settings" {
        "hm rejects Claude native effortLevel in ai.claude.settings" = rejectsChange (settings: (evalHm {ai.claude = {inherit settings;};}).config.ai.claude.settings.reasoningEffort) {
          valid.reasoningEffort = "high";
          invalid = {
            effortLevel = "high";
            reasoningEffort = "high";
          };
          expected = "high";
        };
      }
    );

    module-shared-hooks-reject-non-portable-event = mkTest "shared-hooks-reject-non-portable-event" (
      let
        blocks = [{hooks = [{command = "true";}];}];
        mergedEvents = hooks: builtins.attrNames (evalHm {ai = {inherit hooks;};}).config.ai.hooks;
      in
        checkRows "shared hooks" {
          "ai.hooks accepts PreToolUse but rejects Claude-only ConfigChange" = rejectsChange mergedEvents {
            valid.PreToolUse = blocks;
            invalid.ConfigChange = blocks;
            expected = ["PreToolUse"];
          };
        }
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
        hm = evalHm {};
        devenv = evalDevenv {};
        gitPresetValues = evaluated:
          evaluated.options.stacked-workflows.gitPreset.type.functor.payload.values;
        programParity = package: expectedRootShape: runtimes:
          builtins.removeAttrs (optionShape hm package) ["runtimes"]
          == expectedRootShape
          && builtins.attrNames (programOptions hm package).runtimes == runtimes
          && optionShape hm package == optionShape devenv package;
      in
        checkRows "skill-program option parity" {
          "delegate-routing retains its typed settings and all four runtime branches" = programParity "delegate-routing" {
            credentialUsage = "attribute set of (submodule)";
            enable = "boolean";
            families = "attribute set of attribute set of (submodule)";
            opencodeGo = {
              plan = ''null or one of "go", "go-plus", "go-teams"'';
              pool = "null or string";
              presetScope.excludeModelPrefixes = "attribute set of (null or non-empty string)";
            };
            pools = "attribute set of (submodule)";
            reminder = "submodule";
            reviewPolicy = "submodule";
            routing = "attribute set of (submodule)";
            skill = "submodule";
            workflows = "attribute set of (submodule)";
          } ["claude" "codex" "kimchi" "kiro"];
          "gitPreset stays a top-level companion with all three presets on both backends" =
            gitPresetValues hm == ["full" "minimal" "none"] && gitPresetValues devenv == ["full" "minimal" "none"];
          "peer-communication has no additional program settings and covers every runtime" = programParity "peer-communication" {enable = "boolean";} harnessNames;
          "stacked-workflows has no additional program settings and covers every runtime" = programParity "stacked-workflows" {enable = "boolean";} harnessNames;
        }
    );

    module-program-whole-record-priorities = mkTest "program-whole-record-priorities" (
      let
        packages = {
          delegate-routing = config: config.skills ? delegate-routing;
          peer-communication = config: config.skills ? peer-communication;
          semble = config: config.mcpServers ? semble;
          stacked-workflows = config: config.skills ? stack-plan;
        };
        priorities = {
          default = lib.mkDefault;
          force = lib.mkForce;
        };
        rows = lib.concatMapAttrs (backend: evaluate:
          lib.concatMapAttrs (package: contributes:
            lib.concatMapAttrs (priority: wrap: let
              evaluated = evaluate {
                ai = {
                  claude.enable = true;
                  codex.enable = true;
                  programs.${package} = lib.mkMerge [
                    (wrap {enable = true;})
                    {runtimes.claude.enable = false;}
                  ];
                };
              };
            in {
              "${backend}/${package}/${priority}: Claude opt-out survives whole-record priority" = !(contributes evaluated.config.ai.claude);
              "${backend}/${package}/${priority}: Claude opt-out does not suppress Codex" = contributes evaluated.config.ai.codex;
            })
            priorities)
          packages)
        backends;
      in
        checkRows "skill-package whole-record priorities" rows
    );

    # ── Priority-ordered rule triggers ─────────────────────────────
    module-rule-inclusion-priority-falls-back-per-runtime = mkTest "rule-inclusion-priority-falls-back-per-runtime" (
      let
        evaluated = evalDevenv {
          ai = {
            claude.enable = true;
            copilot.enable = true;
            kiro.cli.enable = true;
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
        checkRows "ordered rule triggers" {
          "Claude skips unsupported auto but retains the requested file matcher" = lib.hasInfix "paths:\n  - \"src/**\"" claude;
          "Copilot skips unsupported auto but retains the requested file matcher" = lib.hasInfix ''applyTo: "src/**"'' copilot;
          "Kiro chooses auto before fileMatch, emitting the description without a matcher" =
            lib.hasInfix ''inclusion: "auto"'' kiro
            && lib.hasInfix ''description: "Load when the task concerns source code"'' kiro
            && !(lib.hasInfix "fileMatchPattern:" kiro);
        }
    );

    module-rule-inclusion-restrictions = mkTest "rule-inclusion-restrictions" (
      let
        text = "SEMANTIC-RULE-BODY.";
        evaluate = enable: rule:
          evalDevenv {
            # Keep a valid sibling in AGENTS.md so the Codex rejection cannot
            # pass merely because an accepted-but-dropped rule leaves no file.
            ai =
              enable
              // {
                rules = {
                  anchor.text = "Keep this document.";
                  semantic = rule;
                };
              };
          };
        claudeRule = rule: (markdownInput (evaluate {claude.enable = true;} rule) ".claude/rules/semantic.md").text;
        codex = evaluate {codex.enable = true;};
        kiroRule = rule: (markdownInput (evaluate {kiro.cli.enable = true;} rule) ".kiro/steering/semantic.md").text;
        autoRule = {
          inherit text;
          description = "Load when semantic guidance applies";
          inclusion = ["auto"];
        };
        codexWithReferences = autoRule // {references = ["docs/semantic.md"];};
        codexControl = codex codexWithReferences;
        hasCodexIndex = evaluated: let
          agentsMd = (markdownInput evaluated "AGENTS.md").text;
        in
          lib.hasInfix "## Rule index" agentsMd
          && lib.hasInfix "Trigger: `auto`" agentsMd
          && lib.hasInfix "Description: Load when semantic guidance applies" agentsMd
          && lib.hasInfix "[`docs/semantic.md`](docs/semantic.md)" agentsMd
          && !(lib.hasInfix text agentsMd);
      in
        checkRows "rule inclusion restrictions" {
          "Claude rejects manual as the only requested trigger" = rejectsChange claudeRule {
            valid = {
              inherit text;
              inclusion = ["always"];
            };
            invalid = {
              inherit text;
              inclusion = ["manual"];
            };
            expected = text;
          };
          "Codex auto rule needs references to render an index entry, not an inline body" = rejectsChange hasCodexIndex {
            valid = codexControl;
            invalid = codex autoRule;
            expected = true;
          };
          "Kiro auto rule needs a non-empty description" = rejectsChange (rule: lib.hasInfix ''inclusion: "auto"'' (kiroRule rule)) {
            valid = autoRule;
            invalid = builtins.removeAttrs autoRule ["description"];
            expected = true;
          };
        }
    );

    module-rule-inclusion-defaults-preserve-rendering = mkTest "rule-inclusion-defaults-preserve-rendering" (
      let
        config = {
          ai = {
            claude.enable = true;
            codex.enable = true;
            copilot.enable = true;
            kiro.cli.enable = true;
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
        copilotScoped = (markdownInput evaluated ".github/instructions/scoped.instructions.md").text;
        kiroScoped = (markdownInput evaluated ".kiro/steering/scoped.md").text;
        agentsMd = (markdownInput evaluated "AGENTS.md").text;
      in
        checkRows "default rule rendering" {
          "Claude does not add matcher front matter to the unscoped rule" = claudeAlways == "DEFAULT-ALWAYS.";
          "Copilot uses the implicit file matcher for applyTo" = lib.hasInfix ''applyTo: "src/**"'' copilotScoped;
          "Kiro keeps the implicit fileMatch trigger and matcher" =
            lib.hasInfix ''inclusion: "fileMatch"'' kiroScoped && lib.hasInfix "fileMatchPattern: \"src/**\"" kiroScoped;
          "shared AGENTS.md retains the implicit always rule" = lib.hasInfix "<!-- rule: always -->" agentsMd && lib.hasInfix "DEFAULT-ALWAYS." agentsMd;
          "shared AGENTS.md retains the implicit scoped rule with its matcher" =
            lib.hasInfix "_Apply this guidance only when working with files matching: `src/**`_" agentsMd
            && lib.hasInfix "DEFAULT-SCOPED." agentsMd;
          "the shared declaration defaults a matching rule to fileMatch" = evaluated.config.ai.rules.scoped.inclusion == ["fileMatch"];
          "the shared declaration defaults an unscoped rule to always" = evaluated.config.ai.rules.always.inclusion == ["always"];
        }
    );

    # ── Normalized keyed-pool suppression types ────────────────────
    # The merge contract itself is covered once per pool in factory-eval.nix.
    # This full-tree check pins the other half: nullable pools accept tombstones,
    # while rules use their entry-local enable flag at every supported scope.
    module-ai-pool-null-types-hm-devenv = mkTest "ai-pool-null-types-hm-devenv" (
      let
        # Semble's generated-entry check also tests nulls over package defaults.
        nullable = backend:
          [
            ["agents"]
            ["claude" "skills"]
          ]
          ++ lib.optional (backend == "hm") ["codex" "agents"]
          ++ [
            ["codex" "environmentVariables"]
            ["codex" "mcpServers"]
            ["codex" "skills"]
            ["environmentVariables"]
            ["kimchi" "environmentVariables"]
            ["kiro" "cli" "environmentVariables"]
            ["kiro" "mcpServers"]
            ["kiro" "skills"]
            ["mcpServers"]
            ["skills"]
          ];
        rules = [
          ["claude" "rules"]
          ["codex" "rules"]
          ["copilot" "github" "rules"]
          ["kiro" "rules"]
          ["rules"]
        ];
        rows = lib.concatMapAttrs (backend: evaluate: let
          nullablePaths = nullable backend;
          config.ai = lib.mkMerge (
            map (path: lib.setAttrByPath (path ++ ["removed"]) null) nullablePaths
            ++ map (path: lib.setAttrByPath (path ++ ["removed" "enable"]) false) rules
          );
          evaluated = evaluate config;
          removed = path: lib.getAttrFromPath (path ++ ["removed"]) evaluated.config.ai;
          label = path: "${backend}/ai.${lib.concatStringsSep "." path}";
        in
          builtins.listToAttrs (
            map (path: lib.nameValuePair "${label path}: accepts a null tombstone" (removed path == null)) nullablePaths
            ++ map (path: lib.nameValuePair "${label path}: accepts an entry-local disable flag" (!(removed path).enable)) rules
          ))
        backends;
      in
        checkRows "pool suppression types" rows
    );
  };
}
