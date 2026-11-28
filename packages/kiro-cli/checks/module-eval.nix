# cspell:ignore batchmode defaut kmux sembleignore
# End-to-end module contracts; the shared harness discovers every backend.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  redact = import ../../../lib/redact {inherit lib;};
  inherit (harness) checkRows deliveredFiles evalDevenv evalHm fromGeneratedTree hasLiteral markdownInput mkTest mkWrapperGrepTest rejectsChange;
  kiroFact = let
    extracted = import ../../../lib/extracted/facts.nix {inherit lib;};
  in
    extracted.get (extracted.load {dir = ../extracted;}).aggregate;
  inherit (import ./helpers.nix {inherit lib pkgs harness;}) idempotentFlags kiroCliSettings kiroSteeringContent kiroWrappedDrvs renderKiroSecrets soleFork soleSame;
  cliOptions = import ../lib/cliOptions.nix {inherit lib;};
  # One value for each of the four launch options, valid by the extracted help.
  launchOptionValues = {
    acp.authMethod = "client";
    chat = {
      mode = "spec";
      requireMcpStartup = true;
      wrap = "never";
    };
  };
  # What the launcher carries for them: one `--name=value` word each, and the
  # rewrite that appends `chat` to a bare launch.
  launchOptionWords = ["--auth-method=client" "--mode=spec" "--require-mcp-startup" "--wrap=never" ''set -- "$@" chat''];
  # The launcher of an evaluated `ai.kiro.cli` for `backend`, with `needles` it
  # must carry and `absentNeedles` it must not.
  launchWrapperTest = {
    absentNeedles ? [],
    config,
    evaluate,
    name,
    needles ? [],
    packages,
  }:
    mkWrapperGrepTest {
      inherit absentNeedles name needles;
      package = builtins.head (packages (evaluate {ai.kiro.cli = {enable = true;} // config;}));
      bin = "kiro-cli";
    };
  mcpFile = ev: ev.config.ai.kiro.files."${ev.config.ai.kiro.configDir}/settings/mcp.json";
  hookFiles = ev: let
    prefix = "${ev.config.ai.kiro.configDir}/hooks/";
  in
    lib.mapAttrs' (path: file: lib.nameValuePair (lib.removePrefix prefix path) file)
    (lib.filterAttrs (path: _: lib.hasPrefix prefix path) (deliveredFiles ev.config));
  hookInput = evaluated: name: let
    entry = evaluated.config.ai.kiro._generatedFiles."${evaluated.config.ai.kiro.configDir}/hooks/${name}.json";
  in
    if entry.content.text != null
    then entry.content.text
    else builtins.readFile entry.content.source;
  settingsWarnings = result: lib.filter (lib.hasPrefix "ai.kiro.cli.native.settings") result.config.warnings;
in {
  checks = {
    # The wrapper argv cases cover the measured value flags. This synthetic
    # table checks that extraction keeps short names and aliases for value
    # options and drops options that take no value.
    module-kiro-launch-value-options = mkTest "kiro-launch-value-options" (
      let
        launchValueOptions = import ../lib/launchValueOptions.nix {inherit lib;};
        option = {
          aliases = [];
          short = null;
          takesValue = true;
        };
      in
        launchValueOptions.valueOptions {
          "--flag" =
            option
            // {
              long = "--flag";
              takesValue = false;
              aliases = ["--other"];
            };
          "--value" =
            option
            // {
              long = "--value";
              short = "-v";
              aliases = ["--alias"];
            };
        }
        == ["--alias" "--value" "-v"]
    );

    # ── Consumer launch options (ai.kiro.cli.{acp,chat}) ─────────────────
    # The classification must judge every extracted option, in both directions,
    # and expose exactly the four settings: a table that missed a new upstream
    # option, kept a removed one, or turned an excluded option into a setting
    # (`--model`, `--trust-tools`, ...) fails here.
    module-kiro-launch-option-classification = mkTest "kiro-launch-option-classification" (
      assert lib.assertMsg (cliOptions.report
        == {
          stale = [];
          unclassified = [];
        }) "cli.options and the classification disagree: ${builtins.toJSON cliOptions.report}";
        lib.concatMap (tier: map (name: "${tier}.${name}") (builtins.attrNames cliOptions.options.${tier})) ["acp" "chat"]
        == ["acp.authMethod" "chat.mode" "chat.requireMcpStartup" "chat.wrap"]
    );

    # The diff itself, on a table with one option each side lacks: a report that
    # compared one direction only would leave one list empty.
    module-kiro-launch-option-classification-diff = mkTest "kiro-launch-option-classification-diff" (
      cliOptions.reportOf {
        classification.top = {
          "--b" = null;
          "--c" = null;
        };
        tables.top = {
          "--a" = null;
          "--b" = null;
        };
      }
      == {
        stale = ["top --c"];
        unclassified = ["top --a"];
      }
    );

    # Force the selected option through each backend's merge. One bad value
    # per restriction distinguishes a loosened enum or bool from a broken eval.
    module-kiro-launch-option-types = mkTest "kiro-launch-option-types" (let
      check = evaluate: option: path: good: bad: let
        read = config: lib.getAttrFromPath path (evaluate {ai.kiro.cli = {enable = true;} // config;}).config.ai.kiro.cli;
      in
        checkRows option {
          "omitting the option leaves it unset" = read {} == null;
          "value outside the declared domain is rejected" = rejectsChange read {
            expected = good;
            invalid = lib.setAttrByPath path bad;
            valid = lib.setAttrByPath path good;
          };
        };
    in
      lib.all (evaluate:
        checkRows "launcher option declarations" {
          "acp.authMethod rejects unknown methods" = check evaluate "authMethod" ["acp" "authMethod"] "cli" "bogus";
          "chat.mode rejects unknown modes" = check evaluate "mode" ["chat" "mode"] "default" "bogus";
          "chat.requireMcpStartup rejects non-booleans" = check evaluate "requireMcpStartup" ["chat" "requireMcpStartup"] false "yes";
          "chat.wrap rejects unknown wrap modes" = check evaluate "wrap" ["chat" "wrap"] "auto" "sometimes";
        }) [evalHm evalDevenv]);

    # Home Manager hands the four configured options to the launcher.
    module-kiro-hm-launch-options = launchWrapperTest {
      name = "kiro-hm-launch-options";
      evaluate = evalHm;
      packages = ev: ev.config.home.packages;
      config = launchOptionValues;
      needles = launchOptionWords;
    };

    # A false flag injects nothing and leaves a bare launch alone.
    module-kiro-devenv-launch-options-false = launchWrapperTest {
      name = "kiro-devenv-launch-options-false";
      evaluate = evalDevenv;
      packages = ev: ev.config.packages;
      config.chat.requireMcpStartup = false;
      absentNeedles = launchOptionWords;
    };

    # With no managed wrapper the options reach nothing, so a consumer who set
    # one is told, naming it; an unset option stays silent.
    module-kiro-package-null-explicit-launch-options-warn = mkTest "kiro-package-null-explicit-launch-options-warn" (
      let
        warnings = eval: config:
          (eval {
            ai.kiro.cli =
              {
                enable = true;
                package = null;
              }
              // config;
          }).config.warnings;
      in
        lib.all (eval:
          warnings eval {}
          == []
          && warnings eval {
            acp.authMethod = "client";
            chat.wrap = "never";
          }
          == ["ai.kiro.cli.package is null, so these settings are inert (they need the managed Kiro wrapper; the system binary runs without them): ai.kiro.cli.acp.authMethod, ai.kiro.cli.chat.wrap. Unset them or set ai.kiro.cli.package."]) [evalHm evalDevenv]
    );

    module-kiro-wrapper-gate = mkTest "kiro-wrapper-gate" (
      checkRows "subcommand gate" {
        # The real argv cases for ACP cover both spellings and the marker,
        # but do not pass an ACP positional containing the option as a substring.
        "only a whole ACP option token can suppress engine injection" = lib.hasInfix "--agent-engine|--agent-engine=*) nat_engine=1 ;;" (idempotentFlags.optionPresenceBlock {
          flag = "--agent-engine";
          var = "nat_engine";
        });
      }
    );

    # A rule configured while the runtime is off cannot write any Kiro file;
    # setting only cli.enable must lift that gate and deliver the exact rule.
    module-kiro-cli-enable-manages = mkTest "kiro-cli-enable-manages" (let
      evaluate = backend: cli:
        backend {
          ai.kiro = {
            inherit cli;
            rules.probe = {
              matcher = ["src/**"];
              text = "probe";
            };
          };
        };
      keys = ev: lib.filter (lib.hasPrefix ".kiro/") (lib.attrNames (deliveredFiles ev.config));
    in
      lib.all (backend: let
        off = evaluate backend {};
        on = evaluate backend {enable = true;};
      in
        checkRows "Kiro runtime enablement" {
          "configured steering stays off without cli.enable" = !off.config.ai.kiro.enable && keys off == [];
          "launcher enablement also delivers the configured rule" = on.config.ai.kiro.enable && lib.elem ".kiro/steering/probe.md" (keys on);
        }) [evalHm evalDevenv]);

    module-kiro-cli-namespace = mkTest "kiro-cli-namespace" (let
      moved = [
        ["backgroundExecution"]
        ["codeToSpec"]
        ["environmentVariables"]
        ["extraPackages"]
        ["features"]
        ["kvim"]
        ["native" "settings"]
        ["normalized" "environmentVariables"]
        ["normalized" "shell"]
        ["package"]
        ["shell"]
        ["tweaks"]
        ["useFhsSandbox"]
        ["workflows"]
      ];
      check = evaluate: let
        result = evaluate {};
        tree = result.options.ai.kiro;
      in
        lib.all (path: !lib.hasAttrByPath path tree && lib.hasAttrByPath (["cli"] ++ path) tree) moved
        && lib.all (key: builtins.hasAttr key tree) ["activation" "agents" "configDir" "context" "enable" "files" "hooks" "mcpServers" "rules" "skills"]
        && tree.cli ? enable
        && tree.enable.readOnly;
    in
      lib.all check [evalHm evalDevenv]);

    module-kiro-cli-normalized-launcher-pools = mkTest "kiro-cli-normalized-launcher-pools" (let
      check = evaluate: let
        base.ai = {
          environmentVariables = {
            KEEP = "root";
            REMOVE = "root";
            REPLACE = "root";
          };
          shell = pkgs.bash;
          kiro.cli.environmentVariables = {
            REMOVE = null;
            REPLACE = "runtime";
          };
        };
        inherited = (evaluate base).config.ai.kiro.cli.normalized;
        added =
          (evaluate (lib.recursiveUpdate base {
            ai.kiro.cli.normalized.environmentVariables.ADDED = "normalized";
          })).config.ai.kiro.cli.normalized;
        forced =
          (evaluate (lib.recursiveUpdate base {
            ai.kiro.cli.normalized = {
              environmentVariables = lib.mkForce {ONLY = "forced";};
              shell = lib.mkForce pkgs.bashNonInteractive;
            };
          })).config.ai.kiro.cli.normalized;
      in
        inherited.environmentVariables
        == {
          KEEP = "root";
          REPLACE = "runtime";
        }
        && inherited.shell == pkgs.bash
        && added.environmentVariables
        == {
          ADDED = "normalized";
          KEEP = "root";
          REPLACE = "runtime";
        }
        && forced.environmentVariables == {ONLY = "forced";}
        && forced.shell == pkgs.bashNonInteractive;
    in
      lib.all check [evalHm evalDevenv]);

    # A friendly switch must select its own raw feature and (on HM only) its
    # own global setting; a conflicting explicit setting still wins.
    module-kiro-cli-friendly-features = mkTest "kiro-cli-friendly-features" (let
      cases = {
        backgroundExecution = {
          feature = "background_execution";
          setting = null;
        };
        codeToSpec = {
          feature = "c2s";
          setting = "enableC2s";
        };
        kvim = {
          feature = "kvim";
          setting = null;
        };
        # 3.1.0 removed the workflows rollout: the setting is the only gate.
        workflows = {
          feature = null;
          setting = "enableWorkflows";
        };
      };
      backends = {
        devenv = {
          evaluate = evalDevenv;
          packages = ev: ev.config.packages;
        };
        hm = {
          evaluate = evalHm;
          packages = ev: ev.config.home.packages;
        };
      };
      check = backend: runner: name: case: let
        base.ai.kiro.cli.enable = true;
        selected = runner.evaluate (lib.recursiveUpdate base {ai.kiro.cli.${name}.enable = true;});
        raw = runner.evaluate (lib.recursiveUpdate base {
          ai.kiro.cli.features.${case.feature}.enable = true;
        });
        gated = case.feature != null;
        plain = runner.evaluate base;
        setting =
          if case.setting == null
          then null
          else selected.config.ai.kiro.cli.native.settings.chat.${case.setting};
        explicitFalse = runner.evaluate (lib.recursiveUpdate base {
          ai.kiro.cli = {
            ${name}.enable = true;
            native.settings.chat = lib.optionalAttrs (case.setting != null) {${case.setting} = false;};
          };
        });
        rawDisabled = runner.evaluate (lib.recursiveUpdate base {
          ai.kiro.cli = {
            ${name}.enable = true;
            features.${case.feature}.enable = false;
          };
        });
      in
        (
          # A switch without a rollout feature leaves the stock package alone.
          if !gated
          then soleSame (kiroWrappedDrvs (runner.packages selected)) (kiroWrappedDrvs (runner.packages plain))
          else
            selected.config.ai.kiro.cli.features.${case.feature}.enable
            && soleSame (kiroWrappedDrvs (runner.packages selected)) (kiroWrappedDrvs (runner.packages raw))
            # These three features all require a patch in the pinned release.
            && soleFork (kiroWrappedDrvs (runner.packages selected)) (kiroWrappedDrvs (runner.packages plain))
        )
        && (
          if case.setting == null
          then selected.config.ai.kiro.cli.native.settings.chat.enableC2s == null && selected.config.ai.kiro.cli.native.settings.chat.enableWorkflows == null
          else if backend == "hm"
          then setting == true && explicitFalse.config.ai.kiro.cli.native.settings.chat.${case.setting} == false
          else setting == null && !(selected.config.ai.kiro.files ? ".kiro/settings/cli.json")
        )
        && (
          !gated
          || lib.any (item:
            !item.assertion
            && item.message == "ai.kiro.cli.${name}.enable is on but ai.kiro.cli.features.${case.feature}.enable is explicitly false")
          rawDisabled.config.assertions
        );
    in
      lib.all (backend:
        checkRows "${backend} friendly rollout wiring" (lib.mapAttrs' (name: case:
          lib.nameValuePair "${name} selects only its native feature and setting" (check backend backends.${backend} name case))
        cases))
      (builtins.attrNames backends));

    # cli.json's complete dotted keys form one struct level. Unknown names warn
    # on both backends; devenv still rejects keys outside its workspace list.
    # Payloads below a complete key stay open.
    module-kiro-native-settings-unrecognized-warns = mkTest "kiro-native-settings-unrecognized-warns" (let
      check = backend: evaluate: let
        unknown = evaluate {
          ai.kiro.cli = {
            enable = true;
            native.settings.chat.defautModel = "future-model";
          };
        };
        known = evaluate {
          ai.kiro.cli = {
            enable = true;
            native.settings = {
              chat.modelDefaults."future.model".futureField = true;
              chat.enableTangentMode = true;
            };
          };
        };
        warnings = settingsWarnings unknown;
      in
        (
          if backend == "hm"
          then lib.all (item: item.assertion) unknown.config.assertions
          else lib.any (item: !item.assertion && lib.hasInfix "chat.defautModel" item.message) unknown.config.assertions
        )
        && builtins.length warnings == 1
        && lib.hasInfix ''ai.kiro.cli.native.settings."chat.defautModel"'' (builtins.head warnings)
        && lib.hasInfix ''did you mean `ai.kiro.cli.native.settings."chat.defaultModel"`'' (builtins.head warnings)
        && (kiroCliSettings unknown)."chat.defautModel" == "future-model"
        && settingsWarnings known == []
        && (kiroCliSettings known)."chat.modelDefaults"."future.model".futureField;
    in
      check "hm" evalHm && check "devenv" evalDevenv);

    module-kiro-native-settings-allowlisted = mkTest "kiro-native-settings-allowlisted" (let
      check = backend: evaluate: let
        plain = evaluate {ai.kiro.cli.enable = true;};
        result = evaluate {
          ai.kiro.cli = {
            allowUnrecognizedSettings = [''"chat.defautModel"''];
            enable = true;
            native.settings.chat.defautModel = "future-model";
          };
        };
        warnings = lib.filter (lib.hasPrefix "ai.kiro.cli.") result.config.warnings;
      in
        plain.config.ai.kiro.cli.allowUnrecognizedSettings
        == []
        && plain.options.ai.kiro.cli.allowUnrecognizedSettings.type.nestedTypes.elemType.check "example"
        && !(plain.options.ai.kiro.cli.allowUnrecognizedSettings.type.nestedTypes.elemType.check 42)
        && warnings == []
        && (kiroCliSettings result)."chat.defautModel" == "future-model"
        && (
          if backend == "hm"
          then lib.all (item: item.assertion) result.config.assertions
          else lib.any (item: !item.assertion && lib.hasInfix "chat.defautModel" item.message) result.config.assertions
        );
    in
      check "hm" evalHm && check "devenv" evalDevenv);

    module-kiro-native-settings-stale-allowlist-warns = mkTest "kiro-native-settings-stale-allowlist-warns" (let
      check = evaluate: let
        result = evaluate {
          ai.kiro.cli = {
            allowUnrecognizedSettings = [''"chat.defaultModel"''];
            enable = true;
            native.settings.chat.defaultModel = "future-model";
          };
        };
        warnings = lib.filter (lib.hasPrefix "ai.kiro.cli.") result.config.warnings;
      in
        lib.all (item: item.assertion) result.config.assertions
        && builtins.length warnings == 1
        && lib.hasPrefix "ai.kiro.cli.allowUnrecognizedSettings: stale allowlist entry" (builtins.head warnings)
        && lib.hasInfix ''"chat.defaultModel"'' (builtins.head warnings)
        && lib.hasInfix "is already declared; remove it." (builtins.head warnings);
    in
      lib.all check [evalHm evalDevenv]);

    # A registry action must not fall back to the untyped tail; genuinely
    # new actions must still round-trip through that tail.
    module-kiro-cli-keybindings-typed = mkTest "kiro-cli-keybindings-typed" (let
      expected = [
        "cancelStream"
        "closeMenu"
        "kmuxKeys"
        "kmuxPrefix"
        "moveToBackground"
        "quit"
        "toggleInterruptBehavior"
        "toggleSessionDashboard"
        "viewDiagram"
      ];
      bindings = evaluate: keybindings: (evaluate {ai.kiro.cli.native.settings.chat = {inherit keybindings;};}).config.ai.kiro.cli.native.settings.chat.keybindings;
      check = evaluate:
        checkRows "Kiro keybinding declarations" {
          "future action is not constrained by a known action's type" = (bindings evaluate {futureAction = 42;}).futureAction == 42;
          "pinned actions all have declared slots" = builtins.attrNames (bindings evaluate {}) == expected;
          "quit binding rejects a number but accepts a key chord" = rejectsChange (quit: (bindings evaluate {inherit quit;}).quit) {
            expected = "ctrl+x";
            invalid = 42;
            valid = "ctrl+x";
          };
        };
    in
      lib.all check [evalHm evalDevenv]);

    module-kiro-package-null-skips-install-keeps-files = mkTest "kiro-package-null-skips-install-keeps-files" (
      let
        config.ai.kiro = {
          context.text = "PACKAGE-NULL-CONTEXT";
          cli = {
            enable = true;
            package = null;
          };
        };
        devenv = evalDevenv config;
        hm = evalHm config;
      in
        devenv.config.packages
        == []
        && hm.config.home.packages == []
        && !(kiroCliSettings hm ? "app.disableAutoupdates")
        && lib.hasInfix "PACKAGE-NULL-CONTEXT" (markdownInput devenv "AGENTS.md").text
        && lib.hasInfix "PACKAGE-NULL-CONTEXT" (kiroSteeringContent hm)."AGENTS.md".text
    );

    module-kiro-package-null-explicit-tweaks-warn = mkTest "kiro-package-null-explicit-tweaks-warn" (
      let
        warns = eval: name: let
          warnings = active:
            (eval {
              ai.kiro = {
                cli = {
                  enable = true;
                  package = null;
                  tweaks.${name} = active;
                };
              };
            }).config.warnings;
        in
          warnings true
          == ["ai.kiro.cli.package is null, so these settings are inert (they need the managed Kiro wrapper; the system binary runs without them): ai.kiro.cli.tweaks.${name}. Unset them or set ai.kiro.cli.package."]
          && warnings false == [];
      in
        builtins.all (
          eval:
            builtins.all (warns eval) ["relativeFileCheckPaths" "stripVendorWorktreeSteering"]
        ) [evalHm evalDevenv]
    );

    module-kiro-package-null-explicit-ssh-workaround-warns = mkTest "kiro-package-null-explicit-ssh-workaround-warns" (
      let
        evaluated = evalDevenv {
          ai = {
            gitSshConfigWorkaround = true;
            kiro = {
              cli = {
                enable = true;
                package = null;
              };
            };
          };
        };
      in
        builtins.all (entry: entry.assertion) evaluated.config.assertions
        && evaluated.config.warnings
        == ["ai.kiro.cli.package is null, so these settings are inert (they need the managed Kiro wrapper; the system binary runs without them): ai.gitSshConfigWorkaround. Unset them or set ai.kiro.cli.package."]
    );

    # Kiro persists settings such as effort only per model in `chat.modelDefaults`,
    # so it has no lossless target for the normalized settings pool, and an
    # unsupported pool has no per-runtime option. Claude is the identical-shape
    # positive control, so an unrelated harness failure cannot make the
    # exclusion pass.
    module-kiro-settings-pool-excluded = mkTest "kiro-settings-pool-excluded" (
      let
        declares = evaluate: runtime:
          (builtins.tryEval
            (evaluate {
              ai.${runtime} = {
                enable = true;
                settings.reasoningEffort = "high";
              };
            })
          .config)
          .success;
      in
        !declares evalHm "kiro"
        && !declares evalDevenv "kiro"
        && declares evalHm "claude"
        && declares evalDevenv "claude"
    );

    # Kiro HM keeps context in the `AGENTS.md` steering entry and emits each keyed
    # rule as `<name>.md` through the common runtime file map.
    module-kiro-hm-context-and-rules = mkTest "kiro-hm-context-and-rules" (
      let
        evaluated = evalHm {
          ai = {
            kiro = {
              cli.enable = true;
              context.text = "CONTEXT-BASELINE-TOKEN.";
              rules = {
                named-rule = {
                  matcher = ["src/**"];
                  text = "NAMED-RULE-BODY-TOKEN.";
                };
                unnamed.text = "UNNAMED-INSTR-TOKEN.";
              };
            };
          };
        };
        steering = kiroSteeringContent evaluated;
        contextFile = (steering."AGENTS.md" or {}).text or "";
        unnamedFile = steering."unnamed.md" or null;
        namedFile = steering."named-rule.md" or null;
      in
        lib.hasInfix "CONTEXT-BASELINE-TOKEN." contextFile
        && !(lib.hasInfix "UNNAMED-INSTR-TOKEN." contextFile)
        && lib.hasInfix "UNNAMED-INSTR-TOKEN." (unnamedFile.text or "")
        && lib.hasInfix "NAMED-RULE-BODY-TOKEN." (namedFile.text or "")
    );

    # Kiro devenv shares repository-root AGENTS.md with Codex for context and
    # always-on rules; scoped rules remain native steering files.
    module-kiro-devenv-context-and-rules = mkTest "kiro-devenv-context-and-rules" (
      let
        evaluated = evalDevenv {
          ai = {
            kiro = {
              cli.enable = true;
              context.text = "CONTEXT-BASELINE-TOKEN.";
              rules = {
                named-rule = {
                  matcher = ["src/**"];
                  text = "NAMED-RULE-BODY-TOKEN.";
                };
                unnamed.text = "UNNAMED-INSTR-TOKEN.";
              };
            };
          };
        };
        steering = kiroSteeringContent evaluated;
        contextFile = (markdownInput evaluated "AGENTS.md").text;
        namedFile = steering."named-rule.md" or null;
      in
        fromGeneratedTree "AGENTS.md" (deliveredFiles evaluated.config)."AGENTS.md"
        && lib.hasInfix "CONTEXT-BASELINE-TOKEN." contextFile
        && lib.hasInfix "UNNAMED-INSTR-TOKEN." contextFile
        && lib.hasInfix "NAMED-RULE-BODY-TOKEN." (namedFile.text or "")
    );

    # Distinct fields which sanitize to one shell name must not overwrite.
    module-kiro-mcp-secret-var-collision-throws = mkTest "kiro-mcp-secret-var-collision-throws" (
      rejectsChange (headers: builtins.attrNames (renderKiroSecrets {a = {inherit headers;};}).secretEnv) {
        expected = ["KIRO_MCP_A_HEADER_X_KEY" "KIRO_MCP_A_HEADER_Y_KEY"];
        invalid = {
          "X-Key" = redact.file "/run/secrets/one";
          "X_Key" = redact.file "/run/secrets/two";
        };
        valid = {
          "X-Key" = redact.file "/run/secrets/one";
          "Y_Key" = redact.file "/run/secrets/two";
        };
      }
    );

    # Pin the template from Kiro's JSON contract, not the production renderer:
    # a shared regression could otherwise pass both backends (and the oracle).
    # The real-file renderers must both consume it, but only devenv changes cwd
    # so that relative URL credential readers resolve against the project.
    module-kiro-hm-devenv-mcp-json-parity = mkTest "kiro-hm-devenv-mcp-json-parity" (let
      cfg.ai.kiro = {
        cli.enable = true;
        mcpServers.jira = {
          headers = {
            "X-Api-Key" = redact.concat ["Bearer " (redact.file "/run/secrets/llm")];
            "X-Jira-Token" = redact.file "/run/secrets/service-token";
            "X-MCP-Servers" = "jira";
          };
          timeout = 300000;
          type = "http";
          url = redact.concat ["https://" (redact.file "/run/secrets/jira-url")];
        };
      };
      dv = mcpFile (evalDevenv cfg);
      hm = mcpFile (evalHm cfg);
      expected = builtins.toJSON {
        mcpServers.jira = {
          headers = {
            "X-Api-Key" = "\${env:KIRO_MCP_JIRA_HEADER_X_API_KEY}";
            "X-Jira-Token" = "\${env:KIRO_MCP_JIRA_HEADER_X_JIRA_TOKEN}";
            "X-MCP-Servers" = "jira";
          };
          timeout = 300000;
          type = "http";
          url = "\${KIRO_MCP_JIRA_URL}";
        };
      };
      # lib.hasInfix's regex needle cannot carry store-path context.
      templatePath = builtins.unsafeDiscardStringContext "${pkgs.writeText "kiro-mcp.json" expected}";
    in
      checkRows "Kiro MCP rendering" {
        "devenv anchors relative credential reads" = hasLiteral ''cd "$NAT_OWN_ROOT"'' dv.content.run;
        "HM keeps the caller cwd" = !(hasLiteral "cd " hm.content.run);
        "template passes public headers and timeout without exposing secret paths" = lib.hasInfix templatePath hm.content.run && lib.hasInfix templatePath dv.content.run;
      });

    # Substitute only the URL variable so Kiro receives the header's literal
    # environment placeholder. The engine fixture covers mode and read failures.
    module-kiro-hm-mcp-json-activation-secret-url = mkTest "kiro-hm-mcp-json-activation-secret-url" (
      let
        result = evalHm {
          ai.kiro = {
            cli.enable = true;
            mcpServers.jira = {
              type = "http";
              url = redact.file "/run/secrets/jira-url";
              headers."X-Jira-Token" = redact.file "/run/secrets/service-token";
            };
          };
        };
      in
        lib.hasInfix "/bin/envsubst '\${KIRO_MCP_JIRA_URL}'" (mcpFile result).content.run
    );

    # A plain HM HTTP server needs no envsubst step in the file engine.
    module-kiro-hm-mcp-json-plain-overwrite = mkTest "kiro-hm-mcp-json-plain-overwrite" (
      let
        result = evalHm {
          ai.kiro = {
            cli.enable = true;
            mcpServers.plain = {
              type = "http";
              url = "https://gw/mcp/";
            };
          };
        };
        unit = mcpFile result;
      in
        !(lib.hasInfix "envsubst" unit.content.run)
    );

    # ── Kiro HM/devenv fanout ────────────────────────────────────

    module-kiro-hm-autoupdate-override = let
      evaluated = evalHm {
        ai.kiro.cli = {
          enable = true;
          native.settings.app.disableAutoupdates = false;
        };
      };
    in
      assert (kiroCliSettings evaluated)."app.disableAutoupdates" == false;
        mkWrapperGrepTest {
          name = "kiro-hm-autoupdate-override";
          package = builtins.head evaluated.config.home.packages;
          bin = "kiro-cli";
          needles = ["export KIRO_NO_AUTO_UPDATE=0"];
        };

    module-kiro-hm-default-settings-emits-writer = mkTest "kiro-hm-default-settings-emits-writer" (
      let
        evaluated = evalHm {ai.kiro.cli.enable = true;};
      in
        kiroCliSettings evaluated
        == {"app.disableAutoupdates" = true;}
        && settingsWarnings evaluated == []
    );

    # Pin a known catalog id and a future id through cli.json on both backends;
    # looking only at the suggestion enum would miss removal of the str fallback.
    module-kiro-default-model-delivery = mkTest "kiro-default-model-delivery" (let
      model = evaluate: value:
        (kiroCliSettings (evaluate {
          ai.kiro.cli = {
            enable = true;
            native.settings.chat.defaultModel = value;
          };
        }))."chat.defaultModel";
    in
      lib.all (evaluate:
        checkRows "defaultModel reaches cli.json" {
          "catalog id is not dropped or rewritten" = model evaluate "auto" == "auto";
          "unknown id is not rejected or rewritten" = model evaluate "some-future-model" == "some-future-model";
        }) [evalHm evalDevenv]);

    # Inspect the suggestion arm separately: accepting through `str` alone
    # would hide a stale or missing independently pinned catalog.
    module-kiro-default-model-suggestions-parity = mkTest "kiro-default-model-suggestions-parity" (
      let
        runtime = import ../lib/mkKiro.nix {
          lib = lib // {ai = import ../../../lib/ai {inherit lib;};};
          inherit pkgs;
        };
        settingsOptions = [
          runtime.options.cli.native.settings
          (evalHm {ai.kiro.cli.enable = true;}).options.ai.kiro.cli.native.settings
          (evalDevenv {ai.kiro.cli.enable = true;}).options.ai.kiro.cli.native.settings
        ];
        extracted = import ../../../lib/extracted/facts.nix {inherit lib;};
        catalog = extracted.get (extracted.load {dir = ../../kiro-model-catalog/extracted;}).aggregate "models";
        modelType = settings: ((settings.type.getSubOptions []).chat.type.getSubOptions []).defaultModel.type;
      in
        lib.all (settings: let
          type = modelType settings;
          suggestions = type.nestedTypes.elemType.nestedTypes.left;
        in
          suggestions.functor.payload.values
          == catalog
          && !(suggestions.check "some-future-model")
          && !(type.check 42))
        settingsOptions
    );

    # Stale engine options must not look accepted while silently doing nothing.
    # Only add the removed field to a config known to install the wrapper.
    module-kiro-engine-options-removed = mkTest "kiro-engine-options-removed" (let
      check = evaluate: packages: let
        read = ai: map (package: package.name) (packages (evaluate {inherit ai;}));
        valid.gitSshConfigWorkaround = false;
        valid.kiro.cli.enable = true;
        expected = ["kiro-cli-wrapped"];
      in
        checkRows "Kiro engine option removals" {
          "old top-level tui switch is not silently ignored" = rejectsChange read {
            inherit expected valid;
            invalid = lib.recursiveUpdate valid {kiro.tui = true;};
          };
          "old v3 switch is not silently ignored" = rejectsChange read {
            inherit expected valid;
            invalid = lib.recursiveUpdate valid {kiro.cli.v3 = true;};
          };
        };
    in
      check evalHm (ev: ev.config.home.packages) && check evalDevenv (ev: ev.config.packages));

    # The default MUST leave the package untouched. This is what protects every
    # cachix hit: an unconditional patch step would fork the drvPath for every
    # consumer, including those who never asked for a dark-shipped feature.
    module-kiro-rollout-default-is-stock = mkWrapperGrepTest {
      name = "kiro-rollout-default-is-stock";
      package = builtins.head (evalHm {ai.kiro.cli.enable = true;}).config.home.packages;
      bin = "kiro-cli";
      needles = ["${pkgs.ai.kiro-cli}/bin/kiro-cli"];
    };

    module-kiro-rollout-coalesces-features = mkTest "kiro-rollout-coalesces-features" (let
      check = evaluate: packages: let
        base.ai.kiro = {
          cli.enable = true;
        };
        drvOf = cli: kiroWrappedDrvs (packages (evaluate (lib.recursiveUpdate base {ai.kiro.cli = cli;})));
      in
        soleSame (drvOf {features.background_execution.enable = true;})
        (drvOf {package = pkgs.ai.kiro-cli.withRolloutFeatures ["background_execution"];})
        && soleSame (drvOf {}) (drvOf {features.test.enable = true;})
        && soleFork (drvOf {features.background_execution.enable = true;}) (drvOf {
          features = {
            background_execution.enable = true;
            kvim.enable = true;
          };
        });
    in
      check evalHm (ev: ev.config.home.packages)
      && check evalDevenv (ev: ev.config.packages));

    # A `package` without the overlay's passthru cannot be patched. Assert the
    # failure is the NAMED one rather than a bare "attribute missing" pointing
    # into factory internals.
    module-kiro-rollout-rejects-package-without-passthru = mkTest "kiro-rollout-rejects-package-without-passthru" (
      let
        ev = evalHm {
          ai.kiro = {
            cli = {
              enable = true;
              package = pkgs.hello;
              features.background_execution.enable = true;
            };
          };
        };
        asserts =
          builtins.filter (a: lib.hasInfix "withRolloutFeatures" a.message)
          ev.config.assertions;
      in
        asserts != [] && (builtins.head asserts).assertion == false
    );

    # The FHS compatibility wrapper remains the default. Opting out makes the
    # launcher exec the overlay's pinned payload rather than the FHS package.
    module-kiro-hm-fhs-opt-out-wrapper-targets-unwrapped = let
      result = evalHm {
        ai.kiro = {
          cli = {
            enable = true;
            useFhsSandbox = false;
          };
        };
      };
    in
      mkWrapperGrepTest {
        name = "kiro-hm-fhs-opt-out-wrapper-targets-unwrapped";
        package = builtins.head result.config.home.packages;
        bin = "kiro-cli";
        needles = ["${pkgs.ai.kiro-cli.unwrapped}/bin/kiro-cli"];
        absentNeedles = ["${pkgs.ai.kiro-cli}/bin/kiro-cli"];
      };

    # A custom package without a supported unwrapped route must fail by the
    # named assertion instead of silently leaving the FHS wrapper enabled.
    module-kiro-fhs-opt-out-rejects-package-without-unwrapped = mkTest "kiro-fhs-opt-out-rejects-package-without-unwrapped" (
      let
        ev = evalHm {
          ai.kiro = {
            cli = {
              enable = true;
              package = pkgs.hello;
              useFhsSandbox = false;
            };
          };
        };
        asserts =
          builtins.filter (a: lib.hasInfix "passthru.unwrapped" a.message)
          ev.config.assertions;
      in
        asserts != [] && (builtins.head asserts).assertion == false
    );

    # A direct-payload package (the overlay's darwin shape) is already
    # unwrapped, so its `unwrapped` route satisfies the opt-out.
    module-kiro-fhs-opt-out-accepts-direct-payload-contract = mkTest "kiro-fhs-opt-out-accepts-direct-payload-contract" (
      let
        directPackage = pkgs.hello.overrideAttrs (attrs: {
          passthru =
            (attrs.passthru or {})
            // {unwrapped = pkgs.hello;};
        });
        ev = evalHm {
          ai.kiro = {
            cli = {
              enable = true;
              package = directPackage;
              useFhsSandbox = false;
            };
          };
        };
        asserts =
          builtins.filter (a: lib.hasInfix "passthru.unwrapped" a.message)
          ev.config.assertions;
      in
        asserts != [] && (builtins.head asserts).assertion == true
    );

    # Use actual extracted flags: the fixture cannot override patchability.
    module-kiro-rollout-rejects-unpatchable = mkTest "kiro-rollout-rejects-unpatchable" (let
      # The extracted pin records code_review as dark and unpatchable,
      # while background_execution is dark and can be patched.
      unpatchable = "code_review";
      patchable = "background_execution";
      check = evaluate: let
        evaluateFeatures = features:
          evaluate {
            ai.kiro.cli = {
              enable = true;
              inherit features;
            };
          };
        refused = evaluateFeatures {${unpatchable}.enable = true;};
        accepted = evaluateFeatures {${patchable}.enable = true;};
      in
        lib.any (item: !item.assertion && lib.hasInfix "ai.kiro.cli.features.${unpatchable}.enable" item.message && lib.hasInfix "rolloutPatchability.${unpatchable}.patchable" item.message) refused.config.assertions
        && lib.all (item: item.assertion) accepted.config.assertions;
    in
      lib.all check [evalHm evalDevenv]);

    # A rollout state must not be treated as GA based on its public percentage
    # alone. Each non-GA input changes one field from the unrestricted control.
    module-kiro-rollout-needs-patch = mkTest "kiro-rollout-needs-patch" (let
      inherit (import ../extract/rollout-coverage.nix) needsPatch;
      ga = {treatment_percent = 100;};
    in
      checkRows "Kiro rollout coverage" {
        "absent channel and segment do not prevent general availability" = !(needsPatch ga);
        "explicit null channel and segment are equivalent to missing fields" =
          !(needsPatch (ga
            // {
              channel = null;
              segment = null;
            }));
        "internal-only segment still requires a patch" = needsPatch (ga // {segment = "internal";});
        "nightly-only channel still requires a patch" = needsPatch (ga // {channel = "nightly";});
        "partial internal exposure still requires a patch" = needsPatch (ga // {internal_treatment_percent = 50;});
        "partial public exposure still requires a patch" = needsPatch (ga // {treatment_percent = 99;});
        "stable and all explicitly permit general availability" =
          !(needsPatch (ga
            // {
              channel = "stable";
              segment = "all";
            }));
        "unrestricted internal exposure does not force a needless patch" = !(needsPatch (ga // {internal_treatment_percent = 100;}));
      });

    module-kiro-raw-features-imply-no-settings = mkTest "kiro-raw-features-imply-no-settings" (let
      check = evaluate: let
        ev = evaluate {
          ai.kiro = {
            cli.enable = true;
            cli = {
              features = {
                c2s.enable = true;
                kvim.enable = true;
              };
            };
          };
        };
      in
        ev.config.ai.kiro.cli.native.settings.chat.enableC2s
        == null
        && ev.config.ai.kiro.cli.native.settings.chat.enableWorkflows == null;
    in
      lib.all check [evalHm evalDevenv]);

    module-kiro-package-null-names-friendly-feature = mkTest "kiro-package-null-names-friendly-feature" (let
      check = evaluate: let
        ev = evaluate {
          ai.kiro = {
            cli.enable = true;
            cli = {
              backgroundExecution.enable = true;
              package = null;
            };
          };
        };
      in
        lib.any (message:
          lib.hasInfix "ai.kiro.cli.backgroundExecution.enable" message
          && !(lib.hasInfix "ai.kiro.cli.features.background_execution.enable" message))
        ev.config.warnings;
    in
      lib.all check [evalHm evalDevenv]);

    # ── flatten boundary: object-valued settings ───────────────────────────────
    # cli.json is flat dotted keys whose VALUES may be objects, and attrset shape
    # alone cannot say where the key stops. Before the boundary these emitted
    # `chat.modelDefaults.claude-opus-5.effort`, which kiro never matches, so the
    # setting was unusable from Nix on BOTH backends.
    module-kiro-devenv-object-valued-setting-stays-nested = mkTest "kiro-devenv-object-valued-setting-stays-nested" (
      let
        result = evalDevenv {
          ai.kiro = {
            cli = {
              enable = true;
              native.settings.chat.modelDefaults."claude-opus-5".effort = "high";
            };
          };
        };
        text = builtins.toJSON (kiroCliSettings result);
      in
        lib.hasInfix ''"chat.modelDefaults":{"claude-opus-5":{"effort":"high"}}'' text
        && !lib.hasInfix "chat.modelDefaults.claude-opus-5" text
        # It is an allowlisted key, so the workspace guard must stay silent —
        # otherwise this would pass while the config was still rejected.
        && builtins.all (a: a.assertion) result.config.assertions
    );

    # Keep the scalar control beside the object cases: only the latter engage
    # the terminal-key boundary. A global-only key must be refused by devenv,
    # not written only to be silently discarded by Kiro. HM owns the global
    # settings file and must still deliver it.
    module-kiro-scalar-setting-still-flattens = mkTest "kiro-scalar-setting-still-flattens" (let
      evaluate = backend: chat:
        backend {
          ai.kiro.cli = {
            enable = true;
            native.settings = {inherit chat;};
          };
        };
      global = {enableWorkflows = true;};
      dropped = evaluate evalDevenv global;
      hm = evaluate evalHm global;
      failures = result: map (item: item.message) (lib.filter (item: !item.assertion) result.config.assertions);
    in
      checkRows "Kiro settings scope and scalar flattening" {
        "devenv identifies the particular global-only key it would discard" = lib.any (lib.hasInfix "silently discarded at runtime: chat.enableWorkflows\n") (failures dropped);
        "HM publishes the global-only key without a workspace rejection" = failures hm == [] && (kiroCliSettings hm)."chat.enableWorkflows" == true;
      });

    # No boundary key may be a strict dotted PREFIX of another. If one ever is, the walk stops at the SHORTER key and
    # writes nested JSON kiro cannot read — the exact defect the boundary fixed,
    # reintroduced by data rather than by code, and invisible to every other test
    # here because `module-kiro-scalar-setting-still-flattens` uses `chat`, which
    # is never terminal, so it never engages the boundary at all.
    #
    # `chat.tools` is the live candidate: `chat.tools.*` is already eleven
    # registry entries, so upstream naming the parent would trip this.
    module-kiro-flatten-boundary-has-no-prefix-pairs = mkTest "kiro-flatten-boundary-has-no-prefix-pairs" (
      let
        keys = lib.unique (kiroFact "settingKeys" ++ kiroFact "workspaceOverridableSettings");
        nested =
          builtins.filter (
            a: builtins.any (b: a != b && lib.hasPrefix "${a}." b) keys
          )
          keys;
      in
        nested == []
    );

    # Both tweaks default off and select package-bound patches on either backend.
    module-kiro-tweaks-default-off-and-parity = mkTest "kiro-tweaks-default-off-and-parity" (
      let
        forks = eval: select: name: let
          a = eval {
            ai.kiro = {
              cli = {
                enable = true;
              };
            };
          };
          b = eval {
            ai.kiro = {
              cli = {
                enable = true;
                tweaks.${name} = true;
              };
            };
          };
        in
          !a.config.ai.kiro.cli.tweaks.${name} && soleFork (kiroWrappedDrvs (select a)) (kiroWrappedDrvs (select b));
        names = ["relativeFileCheckPaths" "stripVendorWorktreeSteering"];
      in
        builtins.all (forks evalHm (v: v.config.home.packages)) names
        && builtins.all (forks evalDevenv (v: v.config.packages)) names
    );

    # `trustedMcpTools` lowers to v3 allow rules in permissions.yaml, the only
    # trust KAS reads, and Home Manager is the only backend that declares it:
    # the YAML generator's store path changes if an entry is dropped or
    # mistranslated. That devenv has no such option is asserted by
    # `ai-warnings-kiro-tool-trust`.
    module-kiro-hm-permissions-trusted-tools = mkTest "kiro-hm-permissions-trusted-tools" (
      let
        hm = evalHm {
          ai.kiro.cli = {
            enable = true;
            trustedMcpTools = ["@openmemory" "@git-intel-mcp/hotspots" "subagent"];
          };
        };
        expected = (pkgs.formats.yaml {}).generate "kiro-permissions.yaml" {
          rules = [
            {
              capability = "mcp";
              effect = "allow";
              match = ["openmemory/*" "git-intel-mcp/hotspots"];
            }
            {
              capability = "subagent";
              effect = "allow";
            }
          ];
        };
      in
        toString hm.config.ai.kiro._generatedFiles.".kiro/settings/permissions.yaml".content.source
        == toString expected
        && hm.config.home.file ? ".kiro/settings/permissions.yaml"
    );

    # HM: keyed rule steering entries with Kiro transformer frontmatter.
    # Verifies the kiro transformer emits `inclusion:` and `name:` fields.
    module-kiro-hm-writes-steering-files = mkTest "kiro-hm-writes-steering-files" (
      let
        result = evalHm {
          ai.kiro = {
            cli.enable = true;
            rules.my-steering = {
              matcher = ["src/**" "tests/**"];
              text = "Use strict mode always.";
            };
          };
        };
        steeringFile = (kiroSteeringContent result)."my-steering.md" or null;
      in
        lib.hasInfix "Use strict mode always" (steeringFile.text or "")
        && lib.hasInfix ''inclusion: "fileMatch"'' (steeringFile.text or "")
        && lib.hasInfix ''name: "my-steering"'' (steeringFile.text or "")
        # CRITICAL: fileMatchPattern MUST be a YAML list for multi-element
        # paths, not a comma-joined string, and a block sequence rather than
        # an inline array so a Markdown formatter cannot reflow it.
        && lib.hasInfix "fileMatchPattern:\n  - \"src/**\"\n  - \"tests/**\"\n" (steeringFile.text or "")
    );

    # Explicit Kiro inclusion modes are carried by runtime-native rules, so the
    # same config must render byte-identically in HM and devenv. Matchers remain
    # available to portable rules but do not leak a
    # fileMatchPattern into Kiro when an explicit non-fileMatch mode wins.
    module-kiro-inclusion-modes-hm-devenv-parity = mkTest "kiro-inclusion-modes-hm-devenv-parity" (
      let
        config = {
          ai = {
            kiro = {
              cli.enable = true;
              rules.on-demand = {
                inclusion = "manual";
                matcher = ["docs/**"];
                text = "Load only when requested.";
              };
              rules.semantic = {
                description = "Semantic project guidance";
                inclusion = "auto";
                matcher = ["src/**"];
                text = "Load when the description matches.";
              };
            };
          };
        };
        hmSteering = kiroSteeringContent (evalHm config);
        devenvSteering = kiroSteeringContent (evalDevenv config);
        manual = (hmSteering."on-demand.md" or {}).text or "";
        auto = (hmSteering."semantic.md" or {}).text or "";
      in
        hmSteering."on-demand.md".text
        == devenvSteering."on-demand.md".text
        && hmSteering."semantic.md".text == devenvSteering."semantic.md".text
        && lib.hasInfix ''inclusion: "manual"'' manual
        && lib.hasInfix ''inclusion: "auto"'' auto
        && lib.hasInfix ''description: "Semantic project guidance"'' auto
        && !(lib.hasInfix "fileMatchPattern:" manual)
        && !(lib.hasInfix "fileMatchPattern:" auto)
    );

    module-kiro-inclusion-is-runtime-native = mkTest "kiro-inclusion-is-runtime-native" (
      let
        portableAttempt = builtins.tryEval (let
          result = evalHm {
            ai.rules.semantic = {
              description = "Semantic project guidance";
              inclusion = "auto";
              text = "Scoped guidance.";
            };
          };
        in
          builtins.deepSeq result.config.ai.rules.semantic true);
      in
        !portableAttempt.success
    );

    # Exercise the enum field through the native rule merge: a free string
    # would accept a mode Kiro does not know how to load.
    module-kiro-inclusion-invalid-enum-rejected = mkTest "kiro-inclusion-invalid-enum-rejected" (
      rejectsChange (inclusion:
        (evalDevenv {
          ai.kiro.rules.probe = {
            inherit inclusion;
            text = "Probe.";
          };
        }).config.ai.kiro.rules.probe.inclusion) {
        expected = "auto";
        invalid = "sometimes";
        valid = "auto";
      }
    );

    # Kiro context follows the backend's AGENTS.md assignment.
    # Check a root-only input separately: its
    # routing must work without any Kiro-specific content to trigger it.
    module-kiro-context-delivery = mkTest "kiro-context-delivery" (let
      config.ai = {
        context.text = "Root context sentinel.";
        kiro.cli.enable = true;
      };
      perRuntime.ai.kiro = {
        cli.enable = true;
        context.text = "Runtime context sentinel.";
      };
      delivers = evaluate: path: inputs: expected: let
        result = evaluate inputs;
      in
        fromGeneratedTree path (deliveredFiles result.config).${path}
        && (markdownInput result path).text == expected;
      hmPath = ".kiro/steering/AGENTS.md";
    in
      checkRows "Kiro context routing" {
        "HM delivers root-only context to the native steering tree" = delivers evalHm hmPath config "Root context sentinel.";
        "devenv delivers root-only context without a runtime override" = delivers evalDevenv "AGENTS.md" config "Root context sentinel.";
        "devenv delivers runtime context only at the repository root" =
          delivers evalDevenv "AGENTS.md" perRuntime "Runtime context sentinel."
          && !((deliveredFiles (evalDevenv perRuntime).config) ? ${hmPath});
      });

    # HM: per-runtime context appends after root context.
    module-kiro-hm-context-composes-root-first = mkTest "kiro-hm-context-composes-root-first" (
      let
        result = evalHm {
          ai.kiro = {
            cli.enable = true;
            context.text = "Per-CLI context.";
          };
          ai.context.text = "Top-level context.";
        };
        contextFile = (kiroSteeringContent result)."AGENTS.md" or null;
      in
        contextFile
        != null
        && contextFile.text == "Top-level context.\n\nPer-CLI context."
    );

    # HM: contextFilename override redirects the context emission.
    module-kiro-hm-context-filename-override = mkTest "kiro-hm-context-filename-override" (
      let
        result = evalHm {
          ai.kiro = {
            cli.enable = true;
            context = {
              filename = "custom.md";
              text = "Custom filename.";
            };
          };
        };
        customFile = (kiroSteeringContent result)."custom.md" or null;
        agentsFile = (kiroSteeringContent result)."AGENTS.md" or null;
      in
        customFile != null && agentsFile == null
    );

    # HM: skills fanout via the staged entries `mkSkillFiles` writes, one link
    # per leaf of the skill tree.
    module-kiro-hm-writes-skills = mkTest "kiro-hm-writes-skills" (
      let
        src = ../../stacked-workflows/skills/stack-fix;
        result = evalHm {
          ai.kiro.cli.enable = true;
          ai.skills.stack-fix = src;
        };
      in
        result.config.ai.claims.path.".kiro/skills/stack-fix"
        == ["kiro"]
        && result.config.home.file.".kiro/skills/stack-fix/SKILL.md".source == "${src}/SKILL.md"
    );

    # HM: extraPackages creates a wrapper carrying the store-backed PATH prefix.
    module-kiro-hm-extra-packages-reach-wrapper = let
      result = evalHm {
        ai.kiro = {
          cli = {
            enable = true;
            extraPackages = [pkgs.which];
          };
        };
      };
    in
      mkWrapperGrepTest {
        name = "kiro-hm-extra-packages-reach-wrapper";
        package = builtins.head result.config.home.packages;
        bin = "kiro-cli";
        needles = ["PATH" "${pkgs.which}/bin"];
      };

    # A normalized root record lowers into `ai.kiro.native.agents.<name>` at
    # mkDefault, field by field: native `permissions` and `tools` merge onto the
    # lowered record, and a native `description` replaces the lowered one.
    module-kiro-root-semantic-agent = mkTest "kiro-root-semantic-agent" (
      let
        config = {
          ai = {
            agents.worker = {
              description = "Reads the workspace";
              instructions.text = "Inspect files without changing them.";
              tools = ["Read"];
            };
            kiro = {
              cli.enable = true;
              native.agents.worker = {
                description = "Reads the workspace natively";
                permissions.rules = [
                  {
                    capability = "filesystem";
                    effect = "deny";
                    match = ["write"];
                  }
                ];
                tools = ["read"];
              };
            };
          };
        };
        emitted = entry: builtins.fromJSON (builtins.readFile entry.source);
        hm = evalHm config;
        devenv = evalDevenv config;
        valid = value:
          value.name
          == "worker"
          && value.description == "Reads the workspace natively"
          && value.prompt == "Inspect files without changing them."
          && value.tools == ["read"]
          && value.permissions.rules
          == [
            {
              capability = "filesystem";
              effect = "deny";
              match = ["write"];
            }
          ];
        quiet = evaluated:
          builtins.filter (lib.hasInfix "ai.agents.worker.tools") evaluated.config.warnings == [];
      in
        valid (emitted hm.config.home.file.".kiro/agents/worker.json")
        && valid (emitted devenv.config.files.".kiro/agents/worker.json")
        && quiet hm
        && quiet devenv
    );

    # A normalized `tools` list names Claude/Copilot tools, which Kiro does not
    # read. It is not lowered; a warning names the native field that restores
    # the guardrail, and the agent is still emitted without it.
    module-kiro-root-agent-tools-warns = mkTest "kiro-root-agent-tools-warns" (
      let
        config = {
          ai = {
            agents.worker = {
              description = "d";
              instructions.text = "p";
              tools = ["Read"];
            };
            kiro.cli.enable = true;
          };
        };
        valid = evaluated:
          builtins.filter (assertion: !assertion.assertion) evaluated.config.assertions
          == []
          && !((builtins.fromJSON evaluated.config.ai.kiro._generatedFiles.".kiro/agents/worker.json".content.text) ? tools);
      in
        valid (evalHm config) && valid (evalDevenv config)
    );

    # Root `ai.agents` takes only the normalized record. A runtime's own file
    # format belongs on `ai.<runtime>.agents`, so text and paths are type
    # errors at the root rather than assertions in each runtime.
    module-kiro-root-raw-agent-type-error = mkTest "kiro-root-raw-agent-type-error" (
      let
        rejected = evaluate: value:
          !(builtins.tryEval (builtins.deepSeq
            (evaluate {
              ai = {
                agents.legacy = value;
                kiro.cli.enable = true;
              };
            }).config.ai.agents
            true)).success;
      in
        lib.all (evaluate:
          rejected evaluate ''{"name": "legacy"}''
          && rejected evaluate ../../claude-code/checks/fixtures/claude-agents/agent-one.md)
        [evalHm evalDevenv]
    );

    # A runtime null is the keyed-pool tombstone: it suppresses the root
    # record, its native lowering and its `tools` warning.
    module-kiro-root-agent-withdrawn = mkTest "kiro-root-agent-withdrawn" (
      let
        config = {
          ai = {
            agents.worker = {
              description = "d";
              instructions.text = "p";
              tools = ["Read"];
            };
            kiro = {
              cli.enable = true;
              agents.worker = null;
            };
          };
        };
        valid = evaluated:
          !(evaluated.config.ai.kiro._generatedFiles ? ".kiro/agents/worker.json")
          && !(evaluated.config.ai.kiro.native.agents ? worker)
          && builtins.filter (lib.hasInfix "ai.agents.worker.tools") evaluated.config.warnings == []
          && builtins.filter (assertion: !assertion.assertion) evaluated.config.assertions == [];
      in
        valid (evalHm config) && valid (evalDevenv config)
    );

    # A raw file bypasses the native layer, so a native record at its key
    # would describe a second file for the same path.
    module-kiro-raw-and-native-agent-same-key-rejected = mkTest "kiro-raw-and-native-agent-same-key-rejected" (
      let
        failed = evaluate:
          map (assertion: assertion.message) (builtins.filter (assertion: !assertion.assertion)
            (evaluate {
              ai.kiro = {
                cli.enable = true;
                agents.worker = ''{"name": "worker"}'';
                native.agents.worker.tools = ["read"];
              };
            }).config.assertions);
      in
        lib.all (evaluate: lib.any (lib.hasInfix "ai.kiro.native.agents worker: ai.kiro.agents sets a raw native file") (failed evaluate)) [evalHm evalDevenv]
    );

    # The Rust CLI rejects a missing name even though ACP accepts one. With
    # no format set the delivered JSON must keep the attr-key name and exact
    # minimal bytes; a Markdown sibling would create a duplicate profile.
    module-kiro-typed-agent-defaults-name = mkTest "kiro-typed-agent-defaults-name" (let
      target = ".kiro/agents/reviewer.json";
      expected = ''{"description":"Reviews diffs","name":"reviewer","prompt":"You review diffs.","tools":["read","shell"]}'';
      config.ai.kiro = {
        cli.enable = true;
        native.agents.reviewer = {
          description = "Reviews diffs";
          prompt.text = "You review diffs.";
          tools = ["read" "shell"];
        };
      };
    in
      lib.all (evaluate: let
        result = evaluate config;
        files = deliveredFiles result.config;
      in
        checkRows "typed agent default JSON" {
          "default format does not emit a duplicate Markdown profile" = !(files ? ".kiro/agents/reviewer.md");
          "generated JSON keeps the default name and omits unused fields" = result.config.ai.kiro._generatedFiles.${target}.format == "json" && (markdownInput result target).text == expected;
          "native file sink delivers the default JSON profile" = fromGeneratedTree target files.${target};
        }) [evalHm evalDevenv]);

    # A native record can select KAS's Markdown profile format. Configuration
    # stays in frontmatter, the prompt becomes the body, and no JSON sibling is
    # delivered for the same agent.
    module-kiro-native-agent-format-markdown = mkTest "kiro-native-agent-format-markdown" (
      let
        config = {
          ai.kiro = {
            cli.enable = true;
            native.agents.writer = {
              description = "Writes release notes";
              format = "markdown";
              includeMcpJson = true;
              prompt.text = "Write concise release notes.";
            };
          };
        };
        valid = evaluated: let
          files = evaluated.config.ai.kiro._generatedFiles;
          entry = files.".kiro/agents/writer.md";
          text = entry.content.text;
        in
          entry.format
          == "markdown"
          && lib.hasPrefix "---\n" text
          && lib.hasInfix "name:" text
          && lib.hasInfix "writer" text
          && lib.hasInfix "description:" text
          && lib.hasInfix "Writes release notes" text
          && lib.hasInfix "includeMcpJson: true\n" text
          && lib.hasSuffix "\n---\n\nWrite concise release notes." text
          && !(lib.hasInfix "format:" text)
          && !(lib.hasInfix "prompt:" text);
      in
        valid (evalHm config) && valid (evalDevenv config)
    );

    # The frontmatter emitter supports only scalars and lists of scalars. A
    # nested field must fail loudly instead of producing a plausible but
    # malformed Markdown profile.
    module-kiro-native-agent-format-markdown-rejects-nested = mkTest "kiro-native-agent-format-markdown-rejects-nested" (
      let
        failed = evaluate:
          map (assertion: assertion.message) (builtins.filter (assertion: !assertion.assertion)
            (evaluate {
              ai.kiro = {
                cli.enable = true;
                native.agents.scoped = {
                  format = "markdown";
                  permissions.rules = [
                    {
                      capability = "filesystem";
                      effect = "deny";
                    }
                  ];
                };
              };
            }).config.assertions);
        namesNestedField = message:
          lib.hasInfix "ai.kiro.native.agents.scoped" message
          && lib.hasInfix "nested field `permissions`" message
          && lib.hasInfix "JSON carries it" message;
      in
        lib.all (evaluate: lib.any namesNestedField (failed evaluate)) [evalHm evalDevenv]
    );

    # Pruning must reach INSIDE list elements. A permission rule declared without
    # `match`/`exclude` still carries their `[]` defaults, and a knowledge-base
    # resource its `include`/`exclude`. A pruner that only walks attrsets returns
    # the list untouched, so those empties reach the emitted file.
    module-kiro-typed-agent-prunes-in-lists = mkTest "kiro-typed-agent-prunes-in-lists" (
      let
        emitted =
          builtins.fromJSON
          (builtins.readFile
            (evalHm {
              ai.kiro = {
                cli.enable = true;
                native.agents.scoped = {
                  description = "d";
                  permissions.rules = [
                    {
                      capability = "shell";
                      effect = "deny";
                    }
                  ];
                  prompt = {
                    enable = false;
                    text = "This disabled prompt must not be emitted.";
                  };
                  resources = [
                    {
                      type = "knowledgeBase";
                      source = "file:///docs";
                    }
                  ];
                };
              };
            })
        .config
        .home
        .file
        .".kiro/agents/scoped.json"
        .source);
        rule = builtins.head emitted.permissions.rules;
        resource = builtins.head emitted.resources;
      in
        rule.capability
        == "shell"
        && rule.effect == "deny"
        && !(emitted ? prompt)
        && !(rule ? match)
        && !(rule ? exclude)
        && resource.source == "file:///docs"
        && !(resource ? include)
        && !(resource ? exclude)
        && !(resource ? name)
    );

    # Force the target text-source record so validation runs during the merge.
    module-kiro-typed-agent-enabled-empty-welcome-message-rejected = mkTest "kiro-typed-agent-enabled-empty-welcome-message-rejected" (
      rejectsChange (welcomeMessage:
        (evalHm {
          ai.kiro = {
            cli.enable = true;
            native.agents.probe = {inherit welcomeMessage;};
          };
        }).config.ai.kiro.native.agents.probe.welcomeMessage.text) {
        expected = "Welcome.";
        invalid.enable = true;
        valid = {
          enable = true;
          text = "Welcome.";
        };
      }
    );

    # An explicit `name` overrides the attr-key default — Kiro keys the agent on
    # `name`, not on the filename, so this has to be reachable.
    module-kiro-typed-agent-explicit-name = mkTest "kiro-typed-agent-explicit-name" (
      let
        evaluated = evalHm {
          ai.kiro = {
            cli.enable = true;
            native.agents.file-stem = {
              name = "explicit-id";
              description = "d";
            };
          };
        };
      in
        fromGeneratedTree ".kiro/agents/file-stem.json" evaluated.config.home.file.".kiro/agents/file-stem.json"
        && (builtins.fromJSON (markdownInput evaluated ".kiro/agents/file-stem.json").text).name
        == "explicit-id"
    );

    # `agentsDir` children expand into raw `ai.kiro.agents` entries, so they
    # blend with named entries and normalized records on both backends. A
    # `.md` child keeps its suffix; a `.json` child and every other agent
    # land as `.json`.
    module-kiro-named-and-dir-agents-coexist = mkTest "kiro-named-and-dir-agents-coexist" (
      let
        config = {
          ai = {
            agents.normalized = {
              description = "d";
              instructions.text = "p";
            };
            kiro = {
              cli.enable = true;
              agents.reviewer = ''{"name":"reviewer"}'';
              agentsDir = ./fixtures/kiro-agents-dir;
            };
          };
        };
        copies = files: path: fixture:
          fromGeneratedTree path files.${path}
          && builtins.fromJSON (builtins.readFile files.${path}.source) == builtins.fromJSON (builtins.readFile fixture);
        valid = files:
          copies files ".kiro/agents/dir-agent.json" ./fixtures/kiro-agents-dir/dir-agent.json
          && files ? ".kiro/agents/md-agent.md"
          && builtins.fromJSON (builtins.readFile files.".kiro/agents/reviewer.json".source) == {name = "reviewer";}
          && files ? ".kiro/agents/normalized.json"
          # The directory itself is never an entry: each child is its own file.
          && !(files ? ".kiro/agents");
        hm = evalHm config;
        devenv = evalDevenv config;
      in
        valid hm.config.home.file
        && valid devenv.config.files
        && builtins.filter (assertion: !assertion.assertion) hm.config.assertions == []
    );

    # `agentsDir` takes every Dir form, and each keeps Kiro's own suffixes:
    # a store-path string (a flake input's "${src}/agents"), any other
    # absolute string, and `{ path; }` with no filter all deliver the `.json`
    # and the `.md` agent. Pure evaluation can read only the store, so the
    # non-store string is the fixture's own path spelled with a leading `//`:
    # it does not start with the store directory, and as a path it resolves
    # to the fixture. It must still ship the file, not its own path as text.
    module-kiro-agents-dir-forms = mkTest "kiro-agents-dir-forms" (
      let
        nonStoreString = "/" + builtins.unsafeDiscardStringContext (toString ./fixtures/kiro-agents-dir);
        delivers = agentsDir: let
          config.ai.kiro = {
            cli.enable = true;
            inherit agentsDir;
          };
          valid = files:
            files ? ".kiro/agents/dir-agent.json"
            && files ? ".kiro/agents/md-agent.md"
            && builtins.fromJSON (builtins.readFile files.".kiro/agents/dir-agent.json".source)
            == builtins.fromJSON (builtins.readFile ./fixtures/kiro-agents-dir/dir-agent.json);
        in
          valid (evalHm config).config.home.file && valid (evalDevenv config).config.files;
      in
        !(lib.hasPrefix "${builtins.storeDir}/" nonStoreString)
        && delivers "${./fixtures/kiro-agents-dir}"
        && delivers nonStoreString
        && delivers {path = ./fixtures/kiro-agents-dir;}
    );

    # `dup.json` and `dup.md` both name agent `dup`, which is ambiguous, so
    # the expansion throws instead of keeping either file.
    module-kiro-agents-dir-stem-collision = mkTest "kiro-agents-dir-stem-collision" (!(builtins.tryEval (builtins.attrNames
      (evalHm {
        ai.kiro = {
          cli.enable = true;
          agentsDir = ./fixtures/kiro-agents-dir-collision;
        };
      })
        .config
        .ai
        .kiro
        .agents))
      .success);

    # Typed records must reach the real-file sink on both backends. Parse the
    # specified envelope rather than grepping field names that could be nested
    # incorrectly or appear in unrelated hooks.
    module-kiro-hooks-typed-hm-emits-envelope = mkTest "kiro-hooks-typed-hm-emits-envelope" (let
      target = ".kiro/hooks/lint.json";
      config.ai.kiro = {
        cli.enable = true;
        hooks.lint = {
          action.command = "just lint";
          matcher = "fs_write";
          timeout = 30;
          trigger = "PostToolUse";
        };
      };
      expected = {
        hooks = [
          {
            action = {
              command = "just lint";
              type = "command";
            };
            matcher = "fs_write";
            name = "lint";
            timeout = 30;
            trigger = "PostToolUse";
          }
        ];
        version = "v1";
      };
      hm = evalHm config;
      dv = evalDevenv config;
      delivers = result: fromGeneratedTree target (hookFiles result)."lint.json" && builtins.fromJSON (hookInput result "lint") == expected;
    in
      checkRows "typed hook delivery" {
        "HM delivers the v1 envelope without null optionals" = delivers hm;
        "devenv delivers the envelope without a files symlink" = delivers dv && !(dv.config.files ? ${target});
      });

    # The trigger soft enum suggests the engine's aliases as well as its
    # canonical triggers. Checked on the enum half alone: the `str` fallback
    # would accept any spelling and prove nothing.
    module-kiro-hooks-trigger-enum-accepts-alias = mkTest "kiro-hooks-trigger-enum-accepts-alias" (
      let
        hooks = (evalHm {ai.kiro.cli.enable = true;}).options.ai.kiro.hooks;
        trigger = (hooks.type.nestedTypes.elemType.getSubOptions []).trigger.type;
        inherit (trigger.nestedTypes) left;
      in
        left.check "SessionStart"
        && left.check "agentSpawn"
        && !(left.check "notATrigger")
    );

    # S1, the arm the shared commandType adds: a package with a `pname` and no
    # `meta.mainProgram` resolves to `bin/<pname>`, as it does for Claude and
    # Codex, and not to its output directory, which is not a runnable command.
    module-kiro-hooks-command-pname-resolves-to-bin = mkTest "kiro-hooks-command-pname-resolves-to-bin" (
      let
        probe = pkgs.stdenvNoCC.mkDerivation {
          pname = "kiro-hook-probe";
          version = "1";
          dontUnpack = true;
          installPhase = "mkdir -p $out/bin";
        };
        result = evalHm {
          ai.kiro = {
            cli.enable = true;
            hooks.probe = {
              trigger = "PostToolUse";
              action.command = probe;
            };
          };
        };
        t = hookInput result "probe";
      in
        lib.hasInfix ''"command":"${builtins.unsafeDiscardStringContext probe.outPath}/bin/kiro-hook-probe"'' (builtins.unsafeDiscardStringContext t)
    );

    module-kiro-hooks-typed-colocation = mkTest "kiro-hooks-typed-colocation" (
      let
        cfg = {
          ai.kiro = {
            cli.enable = true;
            hooks = {
              mem-stop = {
                file = "kiro-memory";
                trigger = "Stop";
                action.command = "/bin/stop";
              };
              mem-recall = {
                file = "kiro-memory";
                trigger = "UserPromptSubmit";
                action.command = "/bin/recall";
              };
              solo = {
                trigger = "PostToolUse";
                matcher = "fs_write";
                action.command = "/bin/solo";
              };
            };
          };
        };
        hookUnits = hookFiles (evalHm cfg);
        # A hook command may be a package, so its input text can carry store
        # context, and every substring inherits the whole string's — which
        # fromJSON rejects. Strip it; byte content is unchanged.
        coText = builtins.unsafeDiscardStringContext (hookInput (evalHm cfg) "kiro-memory");
        co = builtins.fromJSON coText;
        dvUnits = hookFiles (evalDevenv cfg);
      in
        # both co-located records land in ONE kiro-memory.json envelope
        builtins.length co.hooks
        == 2
        && lib.any (h: h.name == "mem-stop" && h.trigger == "Stop") co.hooks
        && lib.any (h: h.name == "mem-recall" && h.trigger == "UserPromptSubmit") co.hooks
        # the Nix-only `file` grouping key is stripped from every emitted hook object
        && !(lib.hasInfix ''"file"'' coText)
        # Ungrouped hooks keep their own <name>.json; grouped hooks do not.
        && builtins.attrNames hookUnits == ["kiro-memory.json" "solo.json"]
        # devenv installs the same grouped inputs from its own generated tree.
        && builtins.attrNames dvUnits == builtins.attrNames hookUnits
        && hookInput (evalDevenv cfg) "kiro-memory" == hookInput (evalHm cfg) "kiro-memory"
        && fromGeneratedTree ".kiro/hooks/kiro-memory.json" dvUnits."kiro-memory.json"
    );

    # A PATH-valued hooksJson entry must emit the file CONTENT, not the path string
    # (mkAllHookFiles resolves paths so devenv's writeText writes the body too).
    module-kiro-hooks-json-path-resolves = mkTest "kiro-hooks-json-path-resolves" (
      let
        result = evalHm {
          ai.kiro = {
            cli.enable = true;
            hooksJson.raw = ./fixtures/kiro-hook-raw.json;
          };
        };
        t = hookInput result "raw";
      in
        lib.hasInfix "raw-envelope-loaded" t
    );

    # Hardening (PR #433 review): require the hook address assertion to name
    # the unsafe inline key or on-disk file, not just any failed assertion.
    # Safe controls engage each of the same input routes and the same guard.
    module-kiro-hooks-file-names = mkTest "kiro-hooks-file-names" (let
      envelope = ''{"hooks":[],"version":"v1"}'';
      guard = evaluate: input: let
        ev = evaluate {ai.kiro = {cli.enable = true;} // input;};
      in
        lib.filter (item: lib.hasInfix "hook file names must match" item.message) ev.config.assertions;
      check = evaluate: valid: invalid: name:
        map (item: item.assertion) (guard evaluate valid)
        == [true]
        && map (item: item.assertion) (guard evaluate invalid) == [false]
        && lib.hasSuffix "offending: ${name}" (builtins.head (guard evaluate invalid)).message;
    in
      lib.all (evaluate:
        checkRows "Kiro hook file names" {
          "directory loader rejects a leading dot in a JSON filename" = check evaluate {hooksDir = ./fixtures/kiro-hooks-dir;} {hooksDir = ./fixtures/kiro-hooks-dir-unsafe;} ".hidden.json";
          "inline loader rejects traversal in a hook address" = check evaluate {hooksJson."kiro-memory.pre_1" = envelope;} {hooksJson."../evil" = envelope;} "../evil.json";
        }) [evalHm evalDevenv]);

    # Raw inline documents must bypass the typed envelope. In devenv a real
    # file is required: Kiro v3 does not discover symlinked hooks.
    module-kiro-devenv-writes-hook-files = mkTest "kiro-devenv-writes-hook-files" (let
      target = ".kiro/hooks/pre-commit.json";
      config.ai.kiro = {
        cli.enable = true;
        hooksJson.pre-commit = ''{"event": "pre-commit"}'';
      };
      hm = evalHm config;
      dv = evalDevenv config;
      delivers = result: let
        files = hookFiles result;
      in
        builtins.attrNames files
        == ["pre-commit.json"]
        && fromGeneratedTree target files."pre-commit.json"
        && builtins.fromJSON (hookInput result "pre-commit") == {event = "pre-commit";};
    in
      checkRows "raw inline hook delivery" {
        "HM preserves the raw JSON at its addressed file" = delivers hm;
        "devenv preserves raw JSON without a native files symlink" = delivers dv && !(dv.config.files ? ${target});
      });

    # Devenv: the external `hooksDir` surface materializes the directory's
    # top-level `*.json` files into `.kiro/hooks/` as real files — same
    # v3-symlink rationale as the inline surface above, same project-root
    # anchoring, and now the SAME manifest, so flipping between the two
    # surfaces prunes the previous one instead of orphaning it.
    #
    # Also pins what is deliberately dropped vs. the retired `cp -rL`: a
    # subdirectory and a non-`.json` sibling in the fixture are BOTH ignored.
    # Kiro loads neither, and the retired whole-dir prune never removed
    # either — but the `.json` filter is additionally what keeps a dotfile
    # like `.gitkeep` from tripping the copy-mode name regex.
    module-kiro-devenv-hooks-dir-materializes = mkTest "kiro-devenv-hooks-dir-materializes" (
      let
        cfg = {
          ai.kiro = {
            cli.enable = true;
            hooksDir = ./fixtures/kiro-hooks-dir;
          };
        };
        result = evalDevenv cfg;
        target = hookFiles result;
        hmTarget = hookFiles (evalHm cfg);
      in
        # Compare the declared input without reading the formatted store tree
        # during evaluation.
        lib.hasInfix "hooks-dir-sample" (hookInput result "sample")
        # HM parity — the same input and ledger reach separate generated trees.
        && hookInput (evalHm cfg) "sample" == hookInput result "sample"
        && fromGeneratedTree ".kiro/hooks/sample.json" hmTarget."sample.json"
        && fromGeneratedTree ".kiro/hooks/sample.json" target."sample.json"
    );

    # ── Kiro steering through ai.kiro.files ─────────────────────────────

    # Two generators producing the same target with divergent whole entries at
    # the same priority must fail. A rule named "AGENTS" and the default context
    # filename deliberately collide here.
    module-kiro-steering-collision-errors = mkTest "kiro-steering-collision-errors" (
      rejectsChange (rules:
        (evalHm {
          ai.kiro = {
            cli.enable = true;
            context.text = "CONTEXT-COLLIDER.";
            inherit rules;
          };
        }).config.ai.kiro._generatedFiles.".kiro/steering/AGENTS.md".content.text) {
        expected = "CONTEXT-COLLIDER.";
        invalid.AGENTS.text = "RULE-COLLIDER.";
        valid = {};
      }
    );

    # Native files must not bring back the retired Kiro steering task.
    module-kiro-steering-retire-task-edges = mkTest "kiro-steering-retire-task-edges" (
      lib.all (files: let
        inherit
          ((evalDevenv {
            ai.kiro.cli.enable = true;
            inherit files;
          }))
          config
          ;
      in
        !(config.tasks ? "ai:kiro:materialize-steering")) [{} {"probe.txt".text = "probe";}]
    );

    # Consumer content replaces generated defaults; `enable = false` suppresses
    # that content before the backend sink.
    module-kiro-steering-consumer-override-and-tombstone = mkTest "kiro-steering-consumer-override-and-tombstone" (
      let
        cfg = {
          ai.kiro = {
            cli.enable = true;
            context.text = "SYMLINK-CTX-TOKEN.";
            rules.symlinked = {
              matcher = ["src/**"];
              text = "SYMLINK-RULE-TOKEN.";
            };
            files = {
              ".kiro/steering/AGENTS.md".content.text = "CONSUMER-CONTEXT.";
              ".kiro/steering/symlinked.md".enable = false;
            };
          };
        };
        hm = evalHm cfg;
        dv = evalDevenv cfg;
      in
        hm.config.ai.files.".kiro/steering/AGENTS.md".content.text
        == "CONSUMER-CONTEXT."
        && !(hm.config.home.file ? ".kiro/steering/symlinked.md")
        && fromGeneratedTree "AGENTS.md" (deliveredFiles dv.config)."AGENTS.md"
        && (markdownInput dv "AGENTS.md").text == "SYMLINK-CTX-TOKEN."
        && !((deliveredFiles dv.config) ? ".kiro/steering/symlinked.md")
    );

    # HM: top-level ai.environmentVariables fans out to the Kiro wrapper.
    #
    # This asserted only that A wrapper appeared, which cannot tell "the
    # top-level value fanned out" apart from "some other trigger wrapped the
    # package" — the fanout, the thing the name promises, went unobserved. HM has
    # no native env surface (the wrapper IS the delivery mechanism), so the value
    # has to be read back out of the shipped script.
    #
    # The sentinel is deliberately distinctive: `grep -F bar` would match store
    # paths incidentally and pass without the fanout ever happening.
    module-kiro-hm-top-level-env-fanout = let
      result = evalHm {
        ai.kiro.cli.enable = true;
        ai.environmentVariables.KIRO_FOO = "kiro-hm-fanout-sentinel";
      };
    in
      mkWrapperGrepTest {
        name = "kiro-hm-top-level-env-fanout";
        package = builtins.head result.config.home.packages;
        bin = "kiro-cli";
        needles = ["KIRO_FOO" "kiro-hm-fanout-sentinel"];
      };

    # Devenv: per-CLI ai.kiro.cli.environmentVariables wins over top-level on name
    # collision. `absentNeedles` is the half that matters — the wrapper baking
    # BOTH values would satisfy a presence-only check while leaving which one
    # actually wins undetermined.
    module-kiro-devenv-per-cli-env-wins = let
      result = evalDevenv {
        ai = {
          kiro.cli.enable = true;
          environmentVariables.SHARED = "top-level-loser";
          kiro.cli.environmentVariables.SHARED = "kiro-specific-winner";
        };
      };
    in
      mkWrapperGrepTest {
        name = "kiro-devenv-per-cli-env-wins";
        package = builtins.head result.config.packages;
        bin = "kiro-cli";
        needles = ["SHARED" "kiro-specific-winner"];
        absentNeedles = ["top-level-loser"];
      };

    # ── ai.*.rulesDir Dir helper ──────────────────────────────────
    # See lib/ai/dir-helpers.nix + lib/ai/sharedOptions.nix + the
    # per-CLI baseline option in hmTransform/devenvTransform.
    # Plan §4: polymorphic `path | { path, filter? }`, default
    # filter keeps `.md`, basename minus `.md` becomes the key
    # (fixes the `.md.md` doubled-extension bug).

    # A consumer filter narrows the directory to the selected Markdown entry.
    module-kiro-rulesdir-path-form = mkTest "kiro-rulesdir-path-form" (let
      path = ./fixtures/kiro-steering;
      keys = rulesDir:
        builtins.attrNames (kiroSteeringContent (evalHm {
          ai.kiro = {
            cli.enable = true;
            inherit rulesDir;
          };
        }));
    in
      checkRows "Kiro rulesDir expansion" {
        "custom filter excludes the two unselected Markdown siblings" =
          keys {
            inherit path;
            filter = name: name == "alpha.md";
          }
          == ["alpha.md"];
      });

    # A per-runtime directory-generated entry replaces the same-key root entry.
    module-kiro-rulesdir-entry-replaces-root-single = mkTest "kiro-rulesdir-entry-replaces-root-single" (
      let
        result = evalHm {
          ai.rules.alpha.text = "explicit top-level";
          ai.kiro = {
            cli.enable = true;
            rulesDir = ./fixtures/kiro-steering;
          };
        };
      in
        lib.hasInfix "Alpha steering body." (kiroSteeringContent result)."alpha.md".text
        && !(lib.hasInfix "explicit top-level" (kiroSteeringContent result)."alpha.md".text)
    );

    # Devenv-side unscoped directory rules join the shared AGENTS.md.
    module-kiro-devenv-rulesdir-path-form = mkTest "kiro-devenv-rulesdir-path-form" (
      let
        result = evalDevenv {
          ai.kiro = {
            cli.enable = true;
            rulesDir = ./fixtures/kiro-steering;
          };
        };
        agents = (markdownInput result "AGENTS.md").text;
      in
        fromGeneratedTree "AGENTS.md" (deliveredFiles result.config)."AGENTS.md"
        && lib.hasInfix "<!-- rule: alpha -->" agents
        && lib.hasInfix "<!-- rule: beta -->" agents
        && lib.hasInfix "<!-- rule: gamma -->" agents
        && !(lib.hasInfix "notes" agents)
    );
  };
}
