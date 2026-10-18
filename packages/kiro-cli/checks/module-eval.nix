# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode defaut sembleignore
{
  lib,
  pkgs,
  harness,
  ...
}: let
  redact = import ../../../lib/redact {inherit lib;};
  inherit (harness) deliveredFiles evalDevenv evalHm fromGeneratedTree hasLiteral markdownInput mkTest mkWrapperGrepTest;
  kiroFact = let
    extracted = import ../../../lib/extracted/facts.nix {inherit lib;};
  in
    extracted.get (extracted.load {dir = ../extracted;}).aggregate;
  inherit (import ./helpers.nix {inherit lib pkgs harness;}) idempotentFlags kiroCliSettings kiroSteeringContent kiroWrappedDrvs renderKiroSecrets renderedMcpJson soleFork soleSame;
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
in {
  checks =
    {
      module-kiro-wrapper-prepend-both = mkTest "kiro-wrapper-prepend-both" (
        let
          b = idempotentFlags.idempotentFlagBlock {
            flags = ["--tui" "--v3"];
            position = "prepend";
          };
          tuiLine = ''if [ "$nat_seen_tui" = 0 ]; then set -- --tui "$@"; fi'';
          v3Line = ''if [ "$nat_seen_v3" = 0 ]; then set -- --v3 "$@"; fi'';
        in
          lib.hasInfix "nat_seen_tui=0" b
          && lib.hasInfix "nat_seen_v3=0" b
          && lib.hasInfix "--tui) nat_seen_tui=1 ;;" b
          && lib.hasInfix "--v3) nat_seen_v3=1 ;;" b
          && lib.hasInfix tuiLine b
          && lib.hasInfix v3Line b
          # reverse emission order is what makes the result `--tui --v3 …`
          && (lib.length (lib.splitString v3Line (lib.head (lib.splitString tuiLine b))) == 2)
      );

      # The append form is still available for a genuinely per-subcommand
      # option, and must NOT be reachable by accident: `position` has no
      # default, since picking the wrong one is the exact bug this guards.
      module-kiro-wrapper-append-form = mkTest "kiro-wrapper-append-form" (
        let
          b = idempotentFlags.idempotentFlagBlock {
            flags = ["--v3"];
            position = "append";
          };
        in
          lib.hasInfix ''if [ "$nat_seen_v3" = 0 ]; then set -- "$@" --v3; fi'' b
          && !(lib.hasInfix "tui" b)
      );

      module-kiro-wrapper-rejects-bad-position =
        mkTest "kiro-wrapper-rejects-bad-position" (!(builtins.tryEval (idempotentFlags.idempotentFlagBlock {
          flags = ["--v3"];
          position = "middle";
        }))
    .success);

      module-kiro-wrapper-idempotent-none = mkTest "kiro-wrapper-idempotent-none" (
        idempotentFlags.idempotentFlagBlock {
          flags = [];
          position = "prepend";
        }
        == ""
      );

      # ── Kiro launcher wrapper: subcommand gating ─────────────────────
      # Used for the options that genuinely ARE per-subcommand: `--tui`
      # (meaningless outside a bare launch and `chat`) and the chat
      # binary's `--trust-tools`. The scan resolves the subcommand into
      # nat_sub; the value-flag arm keeps `--agent acp` from reading as the
      # acp subcommand; `--` parks on a sentinel no gate matches.
      module-kiro-wrapper-subcommand-scan = mkTest "kiro-wrapper-subcommand-scan" (
        let
          b = idempotentFlags.subcommandBlock ["--agent" "--resume-id"];
        in
          lib.hasInfix ''nat_sub=""'' b
          && lib.hasInfix "--agent|--resume-id) nat_skip=1 ;;" b
          && lib.hasInfix ''--) nat_sub="--"; break ;;'' b
          && lib.hasInfix "-*) ;;" b
          && lib.hasInfix ''*) nat_sub="$nat_arg"; break ;;'' b
      );

      # No value-taking options ⇒ no skip arm, but the scan still resolves
      # a subcommand (a wrapper with only boolean options still needs it).
      module-kiro-wrapper-subcommand-scan-boolean-only = mkTest "kiro-wrapper-subcommand-scan-boolean-only" (
        let
          b = idempotentFlags.subcommandBlock [];
        in
          !(lib.hasInfix "nat_skip=1 ;;" b)
          && lib.hasInfix ''*) nat_sub="$nat_arg"; break ;;'' b
      );

      # The gate wraps the injection in a `case` over the accepted set.
      # `bareInvocation` is the empty string, so a gate covering the bare
      # launch emits a `''`-quoted alternative ahead of the named ones.
      module-kiro-wrapper-gate-wraps-injection = mkTest "kiro-wrapper-gate-wraps-injection" (
        let
          b = idempotentFlags.gateOnSubcommand {
            subcommands = [idempotentFlags.bareInvocation "chat"];
            valueFlags = ["--agent"];
          } "INJECTED";
        in
          lib.hasInfix ''case "$nat_sub" in'' b
          && lib.hasInfix "  ''|chat)" b
          && lib.hasInfix "    INJECTED" b
          && lib.hasSuffix "esac" b
      );

      # Nothing to inject ⇒ no gate at all (an env-only wrapper must stay a
      # transparent exec, not grow a dead `case`).
      module-kiro-wrapper-gate-empty-injection = mkTest "kiro-wrapper-gate-empty-injection" (
        idempotentFlags.gateOnSubcommand {subcommands = ["chat"];} "" == ""
      );

      # An empty accepted set can never fire, which would silently drop the
      # injection rather than fail — so it throws instead.
      module-kiro-wrapper-gate-rejects-empty-set = mkTest "kiro-wrapper-gate-rejects-empty-set" (!(builtins.tryEval (idempotentFlags.gateOnSubcommand {subcommands = [];} "INJECTED")).success);

      # `ai.kiro.enable` is read-only and derived from the harness switch, so the
      # one input is `ai.kiro.cli.enable`. Off writes no `.kiro/` file; on writes
      # the scoped steering file through Home Manager and devenv alike.
      module-kiro-default-disabled = mkTest "kiro-default-disabled" (
        let
          rule.ai.kiro.rules.probe = {
            matcher = ["src/**"];
            text = "probe";
          };
          keys = ev: lib.filter (lib.hasPrefix ".kiro/") (lib.attrNames (deliveredFiles ev.config));
        in
          lib.all (eval: let
            off = eval rule;
          in
            !(eval {}).config.ai.kiro.enable
            && !off.config.ai.kiro.enable
            && keys off == [])
          [evalHm evalDevenv]
      );

      module-kiro-cli-enable-manages = mkTest "kiro-cli-enable-manages" (
        let
          on = {
            ai.kiro = {
              cli.enable = true;
              rules.probe = {
                matcher = ["src/**"];
                text = "probe";
              };
            };
          };
          keys = ev: lib.filter (lib.hasPrefix ".kiro/") (lib.attrNames (deliveredFiles ev.config));
        in
          (evalHm on).config.ai.kiro.enable
          && (evalDevenv on).config.ai.kiro.enable
          && lib.all (eval: lib.elem ".kiro/steering/probe.md" (keys (eval on))) [evalHm evalDevenv]
      );

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
          ["sandbox"]
          ["shell"]
          ["trustedMcpTools"]
          ["tweaks"]
          ["useFhsSandbox"]
          ["v3"]
          ["workflows"]
        ];
        check = evaluate: let
          result = evaluate {};
          tree = result.options.ai.kiro;
        in
          lib.all (path: !lib.hasAttrByPath path tree && lib.hasAttrByPath (["cli"] ++ path) tree) moved
          && lib.all (key: builtins.hasAttr key tree) ["activation" "agents" "configDir" "context" "enable" "files" "hooks" "mcpServers" "permissions" "rules" "skills"]
          && tree.cli ? enable
          && tree.enable.readOnly
          && !(builtins.tryEval (evaluate {ai.kiro = {package = null;};}).config).success;
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
          sandbox = {
            feature = "local_sandbox";
            setting = null;
          };
          workflows = {
            feature = "workflows";
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
          base.ai.kiro = {
            cli.enable = true;
            cli.v3 = true;
          };
          selected = runner.evaluate (lib.recursiveUpdate base {ai.kiro.cli.${name}.enable = true;});
          raw = runner.evaluate (lib.recursiveUpdate base {
            ai.kiro.cli.features.${case.feature}.enable = true;
          });
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
          requiresV3 = runner.evaluate (lib.recursiveUpdate base {
            ai.kiro.cli = {
              ${name}.enable = true;
              v3 = false;
            };
          });
          rawDisabled = runner.evaluate (lib.recursiveUpdate base {
            ai.kiro.cli = {
              ${name}.enable = true;
              features.${case.feature}.enable = false;
            };
          });
        in
          soleSame (kiroWrappedDrvs (runner.packages selected)) (kiroWrappedDrvs (runner.packages raw))
          && (
            if !(import ../extract/rollout-coverage.nix).needsPatch (kiroFact "rolloutStates.${case.feature}")
            then soleSame (kiroWrappedDrvs (runner.packages selected)) (kiroWrappedDrvs (runner.packages plain))
            else selected.config.ai.kiro.cli.features.${case.feature}.enable && soleFork (kiroWrappedDrvs (runner.packages selected)) (kiroWrappedDrvs (runner.packages plain))
          )
          && (
            if case.setting == null
            then selected.config.ai.kiro.cli.native.settings.chat.enableC2s == null && selected.config.ai.kiro.cli.native.settings.chat.enableWorkflows == null
            else if backend == "hm"
            then setting == true && explicitFalse.config.ai.kiro.cli.native.settings.chat.${case.setting} == false
            else setting == null && !(selected.config.ai.kiro.files ? ".kiro/settings/cli.json")
          )
          && lib.any (item: !item.assertion && lib.hasInfix "ai.kiro.cli.${name}.enable requires" item.message) requiresV3.config.assertions
          && lib.any (item:
            !item.assertion
            && item.message == "ai.kiro.cli.${name}.enable is on but ai.kiro.cli.features.${case.feature}.enable is explicitly false")
          rawDisabled.config.assertions;
      in
        lib.all (backend: lib.all (name: check backend backends.${backend} name cases.${name}) (builtins.attrNames cases)) (builtins.attrNames backends));

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
          settingsWarnings = result: lib.filter (lib.hasPrefix "ai.kiro.cli.native.settings") result.config.warnings;
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
          && (kiroCliSettings known)."chat.modelDefaults"."future.model".futureField
          && (kiroCliSettings known)."chat.enableTangentMode";
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

      module-kiro-cli-keybindings-typed = mkTest "kiro-cli-keybindings-typed" (let
        expected = map (lib.removePrefix "chat.keybindings.") (lib.filter (lib.hasPrefix "chat.keybindings.") (kiroFact "settingKeys"));
        check = evaluate: let
          plain = evaluate {};
          good = evaluate {
            ai.kiro.cli.native.settings.chat.keybindings = {
              futureAction = 42;
              moveToBackground = "ctrl+x";
            };
          };
          bad = builtins.tryEval (evaluate {ai.kiro.cli.native.settings.chat.keybindings.moveToBackground = 42;}).config.ai.kiro.cli.native.settings.chat.keybindings.moveToBackground;
        in
          builtins.attrNames plain.config.ai.kiro.cli.native.settings.chat.keybindings
          == expected
          && good.config.ai.kiro.cli.native.settings.chat.keybindings.moveToBackground == "ctrl+x"
          && good.config.ai.kiro.cli.native.settings.chat.keybindings.futureAction == 42
          && !bad.success;
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
          && lib.hasInfix "PACKAGE-NULL-CONTEXT" (markdownInput devenv "AGENTS.md").text
          && lib.hasInfix "PACKAGE-NULL-CONTEXT" (kiroSteeringContent hm)."AGENTS.md".text
      );

      module-kiro-package-null-v3-warns = mkTest "kiro-package-null-v3-warns" (
        let
          evaluated = evalDevenv {
            ai.kiro = {
              cli = {
                enable = true;
                package = null;
                v3 = true;
              };
            };
          };
        in
          builtins.all (entry: entry.assertion) evaluated.config.assertions
          && evaluated.config.warnings
          == ["ai.kiro.cli.package is null, so these settings are inert (they need the managed Kiro wrapper; the system binary runs without them): ai.kiro.cli.v3. Unset them or set ai.kiro.cli.package."]
      );

      # Defaults (including the default-on `ai.gitSshConfigWorkaround`) stay
      # silent: the SSH default not reaching a null-package launcher is not a
      # consumer-actionable problem, so nothing warns about it.
      module-kiro-package-null-defaults-silent = mkTest "kiro-package-null-defaults-silent" (
        let
          evaluated = evalDevenv {
            ai.kiro = {
              cli = {
                enable = true;
                package = null;
              };
            };
          };
        in
          builtins.all (entry: entry.assertion) evaluated.config.assertions
          && evaluated.config.packages == []
          && evaluated.config.warnings == []
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

      # Kiro persists effort only inside per-model `chat.modelDefaults` records,
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
          && unnamedFile != null
          && lib.hasInfix "UNNAMED-INSTR-TOKEN." (unnamedFile.text or "")
          && namedFile != null
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
          && !(steering ? "AGENTS.md")
          && namedFile != null
          && lib.hasInfix "NAMED-RULE-BODY-TOKEN." (namedFile.text or "")
      );

      module-kiro-mcp-secret-placeholders = mkTest "kiro-mcp-secret-placeholders" (
        let
          mcpJson = renderedMcpJson {
            jira = {
              type = "http";
              url = redact.concat ["https://" (redact.file "/run/secrets/jira-url")];
              timeout = 300000;
              headers = {
                "X-MCP-Servers" = "jira";
                "X-Jira-Token" = redact.file "/run/secrets/service-token";
                "X-Api-Key" = redact.concat ["Bearer " (redact.file "/run/secrets/llm")];
              };
            };
          };
        in
          lib.hasInfix "\${env:KIRO_MCP_JIRA_HEADER_X_JIRA_TOKEN}" mcpJson
          && lib.hasInfix "\${env:KIRO_MCP_JIRA_HEADER_X_API_KEY}" mcpJson
          && lib.hasInfix "\${KIRO_MCP_JIRA_URL}" mcpJson
          && lib.hasInfix ''"X-MCP-Servers":"jira"'' mcpJson
          && !(lib.hasInfix "/run/secrets/service-token" mcpJson)
          && !(lib.hasInfix "/run/secrets/llm" mcpJson)
          && !(lib.hasInfix "/run/secrets/jira-url" mcpJson)
      );

      # Distinct fields which sanitize to one shell name must not overwrite.
      module-kiro-mcp-secret-var-collision-throws = mkTest "kiro-mcp-secret-var-collision-throws" (!(builtins.tryEval (builtins.deepSeq (renderKiroSecrets {
          a.headers = {
            "X-Key" = redact.file "/run/secrets/one";
            "X_Key" = redact.file "/run/secrets/two";
          };
        })
        true)).success);

      # Kiro HM<->devenv parity: the SAME config yields the SAME rendered
      # mcp.json template on both backends (identical content -> identical
      # store path), each delivered as a REAL file (HM activation / devenv
      # task anchored to $DEVENV_ROOT). Replaces the old home.file
      # symlink parity now that delivery is uniform real-file.
      module-kiro-hm-devenv-mcp-json-parity = mkTest "kiro-hm-devenv-mcp-json-parity" (
        let
          serversCfg = {
            jira = {
              type = "http";
              url = redact.file "/run/secrets/jira-url";
              headers."X-Jira-Token" = redact.file "/run/secrets/service-token";
            };
          };
          cfg = {
            ai.kiro = {
              cli.enable = true;
              mcpServers = serversCfg;
            };
          };
          dv = evalDevenv cfg;
          hmRender = (mcpFile (evalHm cfg)).content.run;
          dvRender = (mcpFile dv).content.run;
          # Same content -> same store path on both backends. Strip the
          # string context: `lib.hasInfix` compiles the needle into a
          # `builtins.match` regex, which rejects a store-path context.
          templatePath = builtins.unsafeDiscardStringContext "${pkgs.writeText "kiro-mcp.json" (renderedMcpJson serversCfg)}";
        in
          lib.hasInfix templatePath hmRender
          && lib.hasInfix templatePath dvRender
          && hasLiteral ''cd "$NAT_OWN_ROOT"'' dvRender
          && !(hasLiteral "cd " hmRender)
          # Both plans name the same destination, each against its own root.
          && (mcpFile (evalHm cfg)).content.run != ""
          && (mcpFile dv).method == "ro"
          && hasLiteral ''TARGET="$NAT_OWN_ROOT/.kiro/settings/mcp.json"'' hmRender
          && hasLiteral ''TARGET="$NAT_OWN_ROOT/.kiro/settings/mcp.json"'' dvRender
      );

      # Kiro HM: a secret url makes mcp.json a REAL-file activation write (NOT
      # a home.file symlink) that exports the url secret, envsubst's ONLY the
      # url var (header ${env:...} survive), and locks the file read-only
      # (secret url -> owner-only 0400).
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
          unit = mcpFile result;
          script = unit.content.run;
        in
          !(result.config.home.file ? ".kiro/settings/mcp.json")
          && result.config.ai.files.".kiro/settings/mcp.json".method == "ro"
          && lib.hasInfix ''TARGET="$NAT_OWN_ROOT/.kiro/settings/mcp.json"'' script
          && lib.hasInfix "/bin/envsubst '\${KIRO_MCP_JIRA_URL}'" script
          # The mode is DECLARED in the plan now, not an argument inside a
          # generated write call: owner-only, because this file holds the
          # substituted url secret.
          && unit.mode == "0400"
          # The secret read must be a BARE assignment whose status errexit can
          # see, then a separate `export`. `export VAR="$(cmd)"` returns export's
          # status (always 0), so a failed read is silent and envsubst writes
          # `"url": ""`. This assertion previously required that exact broken
          # form, which is how the bug shipped.
          && lib.hasInfix ''KIRO_MCP_JIRA_URL="$('' script
          && !(lib.hasInfix ''export KIRO_MCP_JIRA_URL="$('' script)
          && lib.hasInfix "export KIRO_MCP_JIRA_URL\n" script
          && lib.hasInfix "redact-read" script
          && lib.hasInfix "|| exit 1" script
          # Scoped: HM concatenates every activation entry into one script, so an
          # unscoped strict-mode header leaks into later entries and HM's own
          # code, and the exported SECRET would stay live for the rest of
          # activation.
          && lib.hasPrefix "(\nset -euETo pipefail" script
          && lib.hasSuffix ")\n" script
      );

      # Kiro HM: a plain (non-secret) http server still lands as a read-only
      # copy — world-readable 0444, no envsubst step.
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
          unit.mode
          == "0444"
          && !(lib.hasInfix "envsubst" unit.content.run)
          && !(result.config.home.file ? ".kiro/settings/mcp.json")
      );

      # ── Kiro HM/devenv fanout ────────────────────────────────────

      # HM: package installation — verify home.packages populated.
      module-kiro-hm-wraps-package = mkTest "kiro-hm-wraps-package" (
        let
          result = evalHm {
            ai.kiro.cli.enable = true;
          };
          packages = result.config.home.packages;
        in
          builtins.length packages >= 1
      );

      module-kiro-hm-empty-settings-emits-writer = mkTest "kiro-hm-empty-settings-emits-writer" (
        let
          evaluated = evalHm {ai.kiro.cli.enable = true;};
        in
          evaluated.config.ai.files.".kiro/settings/cli.json".method
          == "ro"
          && evaluated.config.ai.files.".kiro/settings/cli.json".mode == null
          && kiroCliSettings evaluated == {}
      );

      module-kiro-hm-writes-settings-activation = mkTest "kiro-hm-writes-settings-activation" (
        let
          result = evalHm {
            ai.kiro = {
              cli = {
                enable = true;
                native.settings.chat.defaultModel = "claude-sonnet-4";
              };
            };
          };
        in
          result.config.ai.files.".kiro/settings/cli.json".method
          == "ro"
          && (kiroCliSettings result)."chat.defaultModel" == "claude-sonnet-4"
      );

      # Known Kiro model id reaches cli.json.
      module-kiro-hm-default-model-known-accepted = mkTest "kiro-hm-default-model-known-accepted" (
        let
          result = evalHm {
            ai.kiro = {
              cli = {
                enable = true;
                native.settings.chat.defaultModel = "claude-opus-4.8";
              };
            };
          };
        in
          (kiroCliSettings result)."chat.defaultModel" == "claude-opus-4.8"
      );

      # Arbitrary (unknown) id is accepted (str branch of the soft enum).
      module-kiro-hm-default-model-arbitrary-accepted = mkTest "kiro-hm-default-model-arbitrary-accepted" (
        let
          result = evalHm {
            ai.kiro = {
              cli = {
                enable = true;
                native.settings.chat.defaultModel = "some-future-model";
              };
            };
          };
        in
          (kiroCliSettings result)."chat.defaultModel" == "some-future-model"
      );

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
            && type.check "some-future-model"
            && !(type.check 42))
          settingsOptions
      );

      module-kiro-devenv-default-model-known-and-arbitrary-accepted = mkTest "kiro-devenv-default-model-known-and-arbitrary-accepted" (
        lib.all (model: let
          result = evalDevenv {
            ai.kiro.cli = {
              enable = true;
              native.settings.chat.defaultModel = model;
            };
          };
        in
          (kiroCliSettings result)."chat.defaultModel" == model)
        ["auto" "some-future-model"]
      );

      # v3 = true triggers the HM wrapper (appends --v3 to the launcher).
      # Stub can't introspect postBuild, but a named symlinkJoin
      # ("kiro-cli-wrapped") is a strong signal the wrapper fired — same
      # fidelity as the copilot wrapper tests.
      module-kiro-hm-v3-wraps-package = mkTest "kiro-hm-v3-wraps-package" (
        let
          result = evalHm {
            ai.kiro = {
              cli = {
                enable = true;
                v3 = true;
              };
            };
          };
          packages = result.config.home.packages;
        in
          lib.any (p: p.name == "kiro-cli-wrapped") packages
      );

      # The `tui` option is GONE. It injected `--tui` and implied `--v3`; `--tui`
      # is redundant under v3 and is going away with it. Setting it must now be a
      # hard eval error, not a silently-ignored key — otherwise a stale consumer
      # config looks accepted while quietly losing the engine flag it depended on.
      module-kiro-hm-tui-option-removed =
        mkTest "kiro-hm-tui-option-removed" (!(builtins.tryEval
          (evalHm {
            ai.kiro = {
              cli.enable = true;
              tui = true;
            };
          })
      .config
      .home
      .packages)
    .success);

      # The unlock must FORK the derivation — if the drvPath were unchanged, the
      # patch step silently did nothing and the consumer would get stock kiro while
      # believing background execution was on. Comparing drvPaths is the only assertion that
      # actually distinguishes those two worlds; a name check cannot, because both
      # sides are named `kiro-cli-wrapped`.
      module-kiro-hm-rollout-unlock-forks-package =
        mkTest "kiro-hm-rollout-unlock-forks-package" (
          let
            a =
              kiroWrappedDrvs
              (evalHm {
                ai.kiro = {
                  cli = {
                    enable = true;
                    v3 = true;
                  };
                };
              })
      .config
      .home
      .packages or [
              ];
            b =
              kiroWrappedDrvs
              (evalHm {
                ai.kiro = {
                  cli = {
                    enable = true;
                    v3 = true;
                    features.background_execution.enable = true;
                  };
                };
              })
      .config
      .home
      .packages or [
              ];
          in
            soleFork a b
        );

      # devenv parity: same fork, same option, same backend-independent result.
      module-kiro-devenv-rollout-unlock-forks-package =
        mkTest "kiro-devenv-rollout-unlock-forks-package" (
          let
            a =
              kiroWrappedDrvs
              (evalDevenv {
                ai.kiro = {
                  cli = {
                    enable = true;
                    v3 = true;
                  };
                };
              })
      .config
      .packages or [
              ];
            b =
              kiroWrappedDrvs
              (evalDevenv {
                ai.kiro = {
                  cli = {
                    enable = true;
                    v3 = true;
                    features.background_execution.enable = true;
                  };
                };
              })
      .config
      .packages or [
              ];
          in
            soleFork a b
        );

      # The default MUST leave the package untouched. This is what protects every
      # cachix hit: an unconditional patch step would fork the drvPath for every
      # consumer, including those who never asked for a dark-shipped feature.
      module-kiro-rollout-default-is-stock = mkTest "kiro-rollout-default-is-stock" (
        let
          packages = (evalHm {ai.kiro.cli.enable = true;}).config.home.packages;
        in
          lib.any (p: (p.drvPath or null) == pkgs.ai.kiro-cli.drvPath) packages
      );

      module-kiro-rollout-coalesces-features = mkTest "kiro-rollout-coalesces-features" (let
        check = evaluate: packages: let
          base.ai.kiro = {
            cli.enable = true;
            cli.v3 = true;
          };
          drvOf = cli: kiroWrappedDrvs (packages (evaluate (lib.recursiveUpdate base {ai.kiro.cli = cli;})));
        in
          soleSame (drvOf {features.background_execution.enable = true;}) (drvOf {
            backgroundExecution.enable = true;
            features.background_execution.enable = true;
          })
          && soleSame (drvOf {features.background_execution.enable = true;})
          (drvOf {package = pkgs.ai.kiro-cli.withRolloutFeatures ["background_execution"];})
          && lib.all (name: soleSame (drvOf {}) (drvOf {features.${name}.enable = true;}))
          ["remote_changelog" "test" "workflows"]
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

      # Positive control for the above — the same assertion must PASS on the
      # overlay-provided package, or the negative proves only that it always fires.
      module-kiro-rollout-accepts-overlay-package = mkTest "kiro-rollout-accepts-overlay-package" (
        let
          ev = evalHm {
            ai.kiro = {
              cli = {
                enable = true;
                features.background_execution.enable = true;
              };
            };
          };
          asserts =
            builtins.filter (a: lib.hasInfix "withRolloutFeatures" a.message)
            ev.config.assertions;
        in
          asserts != [] && (builtins.head asserts).assertion == true
      );

      # The FHS compatibility wrapper remains the default. Opting out selects the
      # overlay's pinned payload rather than a second independently packaged Kiro.
      module-kiro-hm-fhs-opt-out-selects-unwrapped = mkTest "kiro-hm-fhs-opt-out-selects-unwrapped" (
        let
          result = evalHm {
            ai.gitSshConfigWorkaround = false;
            ai.kiro = {
              cli = {
                enable = true;
                useFhsSandbox = false;
              };
            };
          };
          packages = result.config.home.packages;
        in
          builtins.length packages
          == 1
          && (builtins.head packages).drvPath == pkgs.ai.kiro-cli.unwrapped.drvPath
      );

      # Devenv shares the same option and package-selection seam.
      module-kiro-devenv-fhs-opt-out-selects-unwrapped = mkTest "kiro-devenv-fhs-opt-out-selects-unwrapped" (
        let
          result = evalDevenv {
            ai.gitSshConfigWorkaround = false;
            ai.kiro = {
              cli = {
                enable = true;
                useFhsSandbox = false;
              };
            };
          };
          packages = result.config.packages;
        in
          builtins.length packages
          == 1
          && (builtins.head packages).drvPath == pkgs.ai.kiro-cli.unwrapped.drvPath
      );

      # When another option still requires a wrapper, the opt-out must change the
      # wrapper's exec target rather than merely changing the empty-wrapper case.
      # Devenv's default Git SSH export supplies that production-shaped wrapper.
      module-kiro-devenv-fhs-opt-out-wrapper-targets-unwrapped = let
        result = evalDevenv {
          ai.kiro = {
            cli = {
              enable = true;
              useFhsSandbox = false;
            };
          };
        };
      in
        mkWrapperGrepTest {
          name = "kiro-devenv-fhs-opt-out-wrapper-targets-unwrapped";
          package = builtins.head result.config.packages;
          bin = "kiro-cli";
          needles = ["${pkgs.ai.kiro-cli.unwrapped}/bin/kiro-cli"];
          absentNeedles = ["${pkgs.ai.kiro-cli}/bin/kiro-cli"];
        };

      # #956's exact backend: with no unrelated wrapper reason, trustedMcpTools
      # must fork the FHS payload itself. The former outer symlinkJoin had no
      # `fhsenv` passthru and was unreachable during launcher dispatch.
      module-kiro-devenv-trusted-tools-fork-fhs-payload = mkTest "kiro-devenv-trusted-tools-fork-fhs-payload" (
        let
          result = evalDevenv {
            ai.gitSshConfigWorkaround = false;
            ai.kiro = {
              cli = {
                enable = true;
                trustedMcpTools = ["fs_read"];
              };
            };
          };
          packages = result.config.packages;
          configured = builtins.head packages;
        in
          builtins.length packages
          == 1
          && configured ? fhsenv
          && configured.fhsenv.drvPath != pkgs.ai.kiro-cli.fhsenv.drvPath
          && configured.name != "kiro-cli-wrapped"
      );

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

      # Positive control: the overlay package exposes the route and satisfies the
      # same assertion when the opt-out is selected.
      module-kiro-fhs-opt-out-accepts-overlay-package = mkTest "kiro-fhs-opt-out-accepts-overlay-package" (
        let
          ev = evalHm {
            ai.kiro = {
              cli = {
                enable = true;
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

      # The supported pre-split topology is already unwrapped. Its explicit false
      # marker makes opt-out a valid no-op instead of confusing the public
      # `unwrapped` route with evidence that an FHS composition seam is missing.
      module-kiro-fhs-opt-out-accepts-pre-split-contract = mkTest "kiro-fhs-opt-out-accepts-pre-split-contract" (
        let
          preSplitPackage = pkgs.hello.overrideAttrs (attrs: {
            passthru =
              (attrs.passthru or {})
              // {
                kiroFhsSandbox = false;
                unwrapped = pkgs.hello;
              };
          });
          ev = evalHm {
            ai.kiro = {
              cli = {
                enable = true;
                package = preSplitPackage;
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

      # A raw rollout patch without `v3` is INERT, and silently so — the
      # binary really is patched, the option really is set, and the feature never
      # appears. The assertion is all that stands between a consumer and a
      # debugging session, so pin that it actually fires.
      module-kiro-rollout-requires-v3 = mkTest "kiro-rollout-requires-v3" (
        let
          ev = evalHm {
            ai.kiro = {
              cli = {
                enable = true;
                features.background_execution.enable = true;
              };
            };
          };
          asserts =
            builtins.filter (a: lib.hasInfix "requires `v3 = true`" a.message)
            ev.config.assertions;
        in
          asserts != [] && (builtins.head asserts).assertion == false
      );

      # Positive control: the SAME assertion must pass once v3 is set, or the
      # negative above would hold equally for an assertion that always fires.
      module-kiro-rollout-v3-satisfies-assertion = mkTest "kiro-rollout-v3-satisfies-assertion" (
        let
          ev = evalHm {
            ai.kiro = {
              cli = {
                enable = true;
                v3 = true;
                features.background_execution.enable = true;
              };
            };
          };
          asserts =
            builtins.filter (a: lib.hasInfix "requires `v3 = true`" a.message)
            ev.config.assertions;
        in
          asserts != [] && (builtins.head asserts).assertion == true
      );

      # Use actual extracted flags: the fixture cannot override patchability.
      module-kiro-rollout-rejects-unpatchable = mkTest "kiro-rollout-rejects-unpatchable" (let
        needsPatch = name: (import ../extract/rollout-coverage.nix).needsPatch (kiroFact "rolloutStates.${name}");
        names = lib.filter needsPatch (kiroFact "rolloutFeatures");
        unpatchable = builtins.head (lib.filter (name: !(kiroFact "rolloutPatchability.${name}.patchable")) names);
        patchable = builtins.head (lib.filter (name: kiroFact "rolloutPatchability.${name}.patchable") names);
        check = evaluate: let
          evaluateFeatures = features:
            evaluate {
              ai.kiro.cli = {
                enable = true;
                inherit features;
                v3 = true;
              };
            };
          refused = evaluateFeatures {${unpatchable}.enable = true;};
          accepted = evaluateFeatures {
            ${patchable}.enable = true;
            ${unpatchable}.enable = false;
          };
        in
          lib.any (item: !item.assertion && lib.hasInfix "ai.kiro.cli.features.${unpatchable}.enable" item.message && lib.hasInfix "rolloutPatchability.${unpatchable}.patchable" item.message) refused.config.assertions
          && lib.all (item: item.assertion) accepted.config.assertions;
      in
        lib.all check [evalHm evalDevenv]);

      module-kiro-rollout-needs-patch = mkTest "kiro-rollout-needs-patch" (let
        inherit (import ../extract/rollout-coverage.nix) needsPatch;
        ga = {treatment_percent = 100;};
      in
        lib.all (state: !(needsPatch state)) [
          ga
          (ga
            // {
              channel = null;
              segment = null;
            })
          (ga
            // {
              channel = "stable";
              segment = "all";
            })
          (ga // {internal_treatment_percent = 100;})
        ]
        && lib.all needsPatch [(ga // {treatment_percent = 99;}) (ga // {channel = "nightly";}) (ga // {segment = "internal";}) (ga // {internal_treatment_percent = 50;})]);

      module-kiro-raw-features-imply-no-settings = mkTest "kiro-raw-features-imply-no-settings" (let
        check = evaluate: let
          ev = evaluate {
            ai.kiro = {
              cli.enable = true;
              cli = {
                features = {
                  c2s.enable = true;
                  workflows.enable = true;
                };
                v3 = true;
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
                v3 = true;
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

      # Parity: the HM copy carries the same nesting. Both backends
      # share one `flattenKiroSettings`, and this is what pins that they do.
      module-kiro-hm-object-valued-setting-stays-nested = mkTest "kiro-hm-object-valued-setting-stays-nested" (
        let
          result = evalHm {
            ai.kiro = {
              cli = {
                enable = true;
                native.settings.chat.modelDefaults."claude-opus-5".effort = "high";
              };
            };
          };
          declared = kiroCliSettings result;
        in
          declared."chat.modelDefaults"."claude-opus-5".effort
          == "high"
          && !(declared ? "chat.modelDefaults.claude-opus-5")
          && !(declared ? chat)
      );

      # Control: the boundary must stop the walk only AT a known key, never before
      # it. Without this, a flattener that gave up at depth one would pass both
      # tests above while writing nested `{"chat":{...}}` that kiro cannot read.
      module-kiro-scalar-setting-still-flattens = mkTest "kiro-scalar-setting-still-flattens" (
        let
          result = evalDevenv {
            ai.kiro = {
              cli = {
                enable = true;
                native.settings.chat.enableTangentMode = true;
              };
            };
          };
          text = builtins.toJSON (kiroCliSettings result);
        in
          lib.hasInfix ''"chat.enableTangentMode":true'' text
          && !lib.hasInfix ''"chat":{'' text
      );

      # ── workspace-settings allowlist (devenv only) ─────────────────────────────
      # A global-only key written to the project-local cli.json is read and dropped
      # by kiro with no warning, so the module refuses it instead of emitting a file
      # that looks applied.
      module-kiro-devenv-rejects-global-only-setting = mkTest "kiro-devenv-rejects-global-only-setting" (
        let
          ev = evalDevenv {
            ai.kiro = {
              cli = {
                enable = true;
                v3 = true;
                native.settings.chat.enableWorkflows = true;
              };
            };
          };
          asserts =
            builtins.filter (a: lib.hasInfix "silently discarded at runtime" a.message)
            ev.config.assertions;
        in
          asserts != [] && (builtins.head asserts).assertion == false
      );

      # Positive control: an ALLOWLISTED key must sail through the same guard, or
      # the negative above would hold equally for an assertion that always fires.
      module-kiro-devenv-accepts-workspace-setting = mkTest "kiro-devenv-accepts-workspace-setting" (
        let
          ev = evalDevenv {
            ai.kiro = {
              cli = {
                enable = true;
                v3 = true;
                native.settings.chat.enableTangentMode = true;
              };
            };
          };
          asserts =
            builtins.filter (a: lib.hasInfix "silently discarded at runtime" a.message)
            ev.config.assertions;
        in
          asserts == [] && builtins.all (a: a.assertion) ev.config.assertions
      );

      # The HM backend writes the GLOBAL file, where every key is honored. The same
      # config that fails under devenv must pass here, or the guard has leaked out
      # of the backend that owns it.
      module-kiro-hm-accepts-global-only-setting = mkTest "kiro-hm-accepts-global-only-setting" (
        let
          ev = evalHm {
            ai.kiro = {
              cli = {
                enable = true;
                v3 = true;
                native.settings.chat.enableWorkflows = true;
              };
            };
          };
        in
          builtins.all (a: a.assertion) ev.config.assertions
      );

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

      # The keys the flatten-boundary and allowlist fixtures rest on are the
      # consumer needs of `checks.kiro-cli-extracted`; what `expect` cannot say is
      # an absence, so it stays here. This is NOT a test of the extractor:
      # `checks/kiro-workspace-settings-fixtures` drives the real script.
      #
      # The absence check is deliberate and is the fact the devenv assertion's whole
      # message rests on: if upstream ever adds `chat.enableWorkflows` to the
      # allowlist, this failing is the signal to relax that guidance rather than a
      # defect to route around.
      module-kiro-workspace-allowlist-from-sidecar = mkTest "kiro-workspace-allowlist-from-sidecar" (!(lib.elem "chat.enableWorkflows" (kiroFact "workspaceOverridableSettings")));

      # Both tweaks default off and select package-bound patches on either backend.
      module-kiro-tweaks-default-off-and-parity = mkTest "kiro-tweaks-default-off-and-parity" (
        let
          forks = eval: select: name: let
            a = eval {
              ai.kiro = {
                cli = {
                  enable = true;
                  v3 = true;
                };
              };
            };
            b = eval {
              ai.kiro = {
                cli = {
                  enable = true;
                  tweaks.${name} = true;
                  v3 = true;
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

      # Devenv parity: v3 must wrap here too. Disable the Git SSH default so v3 is
      # the sole wrapper reason; otherwise this passes vacuously on the environment
      # export even if the flag wiring disappears.
      module-kiro-devenv-v3-wraps-package = mkTest "kiro-devenv-v3-wraps-package" (
        let
          result = evalDevenv {
            ai.gitSshConfigWorkaround = false;
            ai.kiro = {
              cli = {
                enable = true;
                v3 = true;
              };
            };
          };
          packages = result.config.packages;
        in
          lib.any (p: p.name == "kiro-cli-wrapped") packages
      );

      # devenv parity for the removal: the option must be absent on both backends.
      module-kiro-devenv-tui-option-removed =
        mkTest "kiro-devenv-tui-option-removed" (!(builtins.tryEval
          (evalDevenv {
            ai.kiro = {
              cli.enable = true;
              tui = true;
            };
          })
      .config
      .packages)
    .success);

      # devenv: with no v3/trust and no env, the package is installed RAW (the
      # shared wrapper returns the unwrapped derivation — no needless symlinkJoin).
      # Opts out of `gitSshConfigWorkaround`: on devenv that default reaches Kiro
      # through `environmentVariables`, which is itself a reason to wrap. Leaving
      # it on would make this pass or fail on the SSH default rather than on the
      # wrapper gate it exists to test.
      module-kiro-devenv-no-flags-no-wrap = mkTest "kiro-devenv-no-flags-no-wrap" (
        let
          result = evalDevenv {
            ai.kiro.cli.enable = true;
            ai.gitSshConfigWorkaround = false;
          };
          packages = result.config.packages;
        in
          builtins.length packages
          == 1
          && (builtins.head packages).drvPath == result.config.ai.kiro.cli.package.drvPath
          && !(lib.any (p: p.name == "kiro-cli-wrapped") packages)
      );

      # HM: mcp.json — mergedServers deliver via a real-file activation write
      # (uniform real-file; no home.file symlink). Verify the activation
      # script exists and targets the mcp.json path.
      module-kiro-hm-writes-mcp-json = mkTest "kiro-hm-writes-mcp-json" (
        let
          result = evalHm {
            ai.kiro.cli.enable = true;
            ai.mcpServers.test-server = {
              type = "stdio";
              package = pkgs.hello;
              command = "hello";
            };
          };
          target = mcpFile result;
        in
          target.method
          == "ro"
          && result.config.ai.files.".kiro/settings/mcp.json".method == "ro"
          && target.content.run != null
          && !(result.config.home.file ? ".kiro/settings/mcp.json")
      );

      # HM: explicit `permissions` rules render permissions.yaml (source is a
      # pkgs.formats.yaml derivation, so we assert the file ENTRY exists).
      module-kiro-hm-permissions-explicit-rendered = mkTest "kiro-hm-permissions-explicit-rendered" (
        let
          result = evalHm {
            ai.kiro = {
              cli.enable = true;
              permissions = [
                {
                  capability = "mcp";
                  effect = "allow";
                  match = ["openmemory/*"];
                }
              ];
            };
          };
        in
          (result.config.home.file.".kiro/settings/permissions.yaml" or null) != null
      );

      # HM: under v3 (tui implies v3), `trustedMcpTools` is translated into
      # permissions.yaml — so the file is written even with no explicit rules.
      module-kiro-hm-permissions-translated-under-v3 = mkTest "kiro-hm-permissions-translated-under-v3" (
        let
          result = evalHm {
            ai.kiro = {
              cli = {
                enable = true;
                v3 = true;
                trustedMcpTools = ["@openmemory" "@git-intel-mcp/hotspots" "subagent" "use_aws"];
              };
            };
          };
        in
          (result.config.home.file.".kiro/settings/permissions.yaml" or null) != null
      );

      # HM: without v3 (no tui, no v3) and no explicit permissions, the
      # trustedMcpTools list is NOT translated — no permissions.yaml written.
      module-kiro-hm-permissions-absent-without-v3 = mkTest "kiro-hm-permissions-absent-without-v3" (
        let
          result = evalHm {
            ai.kiro = {
              cli = {
                enable = true;
                trustedMcpTools = ["@openmemory"];
              };
            };
          };
        in
          !(result.config.home.file ? ".kiro/settings/permissions.yaml")
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
          steeringFile
          != null
          && lib.hasInfix "Use strict mode always" (steeringFile.text or "")
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
          native = evalHm {
            ai.kiro = {
              cli.enable = true;
              rules.semantic = {
                description = "Semantic project guidance";
                inclusion = "auto";
                text = "Scoped guidance.";
              };
            };
          };
          kiro = ((kiroSteeringContent native)."semantic.md" or {}).text or "";
        in
          !portableAttempt.success
          && lib.hasInfix ''inclusion: "auto"'' kiro
          && !(lib.hasInfix "fileMatchPattern:" kiro)
      );

      module-kiro-inclusion-invalid-enum-rejected = mkTest "kiro-inclusion-invalid-enum-rejected" (
        let
          ruleAttempt = builtins.tryEval (let
            result = evalDevenv {
              ai.kiro.rules.invalid = {
                inclusion = "sometimes";
                text = "Invalid";
              };
            };
          in
            builtins.deepSeq result.config.ai.kiro.rules.invalid true);
        in
          !ruleAttempt.success
      );

      # HM: per-CLI context → the `<contextFilename>` steering entry
      # (default AGENTS.md), delivered by the ordinary runtime file sink.
      module-kiro-hm-writes-context = mkTest "kiro-hm-writes-context" (
        let
          result = evalHm {
            ai.kiro = {
              cli.enable = true;
              context.text = "Project conventions go here.";
            };
          };
          contextFile = (kiroSteeringContent result)."AGENTS.md" or null;
        in
          contextFile
          != null
          && lib.hasInfix "Project conventions" (contextFile.text or "")
          && fromGeneratedTree ".kiro/steering/AGENTS.md" result.config.home.file.".kiro/steering/AGENTS.md"
          && (markdownInput result ".kiro/steering/AGENTS.md").text == contextFile.text
      );

      # HM: top-level ai.context fans out to kiro when per-CLI unset.
      module-kiro-hm-top-level-context-fallback = mkTest "kiro-hm-top-level-context-fallback" (
        let
          result = evalHm {
            ai.kiro.cli.enable = true;
            ai.context.text = "Top-level context flows everywhere.";
          };
          contextFile = (kiroSteeringContent result)."AGENTS.md" or null;
        in
          contextFile
          != null
          && lib.hasInfix "Top-level context" (contextFile.text or "")
      );

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
          result.config.ai.filesOwners.".kiro/skills/stack-fix"
          == ["kiro"]
          && result.config.home.file.".kiro/skills/stack-fix/SKILL.md".source == "${src}/SKILL.md"
      );

      # HM: setting env vars PRODUCES a wrapper. Renamed from
      # `...-wrapper-exports-env-vars` — it never observed an export, only that the
      # installed package was the wrapped derivation. The export itself is asserted
      # behaviorally in packages/kiro-cli/checks/kiro-wrapper-argv.nix, which runs the wrapper and
      # reads `KIRO_WRAPPER_TEST` back out of the process.
      module-kiro-hm-env-vars-produce-wrapper = mkTest "kiro-hm-env-vars-produce-wrapper" (
        let
          result = evalHm {
            ai.kiro = {
              cli = {
                enable = true;
                environmentVariables.KIRO_LOG_LEVEL = "debug";
              };
            };
          };
          packages = result.config.home.packages;
          first = builtins.head packages;
        in
          builtins.length packages
          == 1
          && first.name == "kiro-cli-wrapped"
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

      # Devenv uses the same option and wrapper path as Home Manager.
      module-kiro-devenv-extra-packages-reach-wrapper = let
        result = evalDevenv {
          ai.kiro = {
            cli = {
              enable = true;
              extraPackages = [pkgs.which];
            };
          };
        };
      in
        mkWrapperGrepTest {
          name = "kiro-devenv-extra-packages-reach-wrapper";
          package = builtins.head result.config.packages;
          bin = "kiro-cli";
          needles = ["PATH" "${pkgs.which}/bin"];
        };

      # HM: no wrapper when nothing to wrap.
      module-kiro-hm-no-wrapper-when-nothing-to-wrap = mkTest "kiro-hm-no-wrapper-when-nothing-to-wrap" (
        let
          result = evalHm {
            ai.kiro.cli.enable = true;
          };
          packages = result.config.home.packages;
          first = builtins.head packages;
        in
          builtins.length packages
          == 1
          && first.drvPath == result.config.ai.kiro.cli.package.drvPath
          && first.name != "kiro-cli-wrapped"
      );

      # HM: agent JSON files written under configDir/agents/.
      module-kiro-hm-writes-agent-files = mkTest "kiro-hm-writes-agent-files" (
        let
          result = evalHm {
            ai.kiro = {
              cli.enable = true;
              agents.reviewer = ''{"role": "reviewer"}'';
            };
          };
          agentFile = result.config.home.file.".kiro/agents/reviewer.json" or null;
        in
          agentFile != null
      );

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
          expected = "Set ai.kiro.native.agents.worker.tools (capability tags";
          valid = evaluated:
            lib.any (lib.hasInfix expected) evaluated.config.warnings
            && builtins.filter (assertion: !assertion.assertion) evaluated.config.assertions == []
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

      # A TYPED agent record lowers to JSON with `name` defaulted from the attr
      # key. That default is the whole point of the typed surface: Kiro's Rust CLI
      # REJECTS an agent file with no `name`, while the Node/ACP parser treats it
      # as optional — so an omission is invisible from the IDE and fatal on the
      # CLI. Also asserts null/empty fields are dropped, keeping the emitted file
      # to the minimal shape both parsers accept.
      module-kiro-typed-agent-defaults-name = mkTest "kiro-typed-agent-defaults-name" (
        let
          evaluated = backend:
            backend {
              ai.kiro = {
                cli.enable = true;
                native.agents.reviewer = {
                  description = "Reviews diffs";
                  prompt.text = "You review diffs.";
                  tools = ["read" "shell"];
                };
              };
            };
          hm = evaluated evalHm;
          devenv = evaluated evalDevenv;
          hmJson = builtins.fromJSON (markdownInput hm ".kiro/agents/reviewer.json").text;
          devenvJson = builtins.fromJSON (markdownInput devenv ".kiro/agents/reviewer.json").text;
          wellFormed = j:
            j.name
            == "reviewer"
            && j.description == "Reviews diffs"
            && j.prompt == "You review diffs."
            && j.tools == ["read" "shell"]
            # null/empty optionals must not reach the file
            && !(j ? model)
            && !(j ? dispatchKind)
            && !(j ? resources)
            && !(j ? permissions);
        in
          fromGeneratedTree ".kiro/agents/reviewer.json" hm.config.home.file.".kiro/agents/reviewer.json"
          && fromGeneratedTree ".kiro/agents/reviewer.json" devenv.config.files.".kiro/agents/reviewer.json"
          && wellFormed hmJson
          && wellFormed devenvJson
          && hmJson == devenvJson
      );

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
            && !(lib.hasInfix "prompt:" text)
            && !(files ? ".kiro/agents/writer.json");
        in
          valid (evalHm config) && valid (evalDevenv config)
      );

      # Leaving `format` unset preserves the exact JSON bytes emitted before the
      # option existed, including the defaulted name and recursive pruning.
      module-kiro-native-agent-format-default-json = mkTest "kiro-native-agent-format-default-json" (
        let
          config = {
            ai.kiro = {
              cli.enable = true;
              native.agents.reviewer = {
                description = "Reviews diffs";
                prompt.text = "You review diffs.";
                tools = ["read" "shell"];
              };
            };
          };
          expected = ''{"description":"Reviews diffs","name":"reviewer","prompt":"You review diffs.","tools":["read","shell"]}'';
          valid = evaluated: let
            files = evaluated.config.ai.kiro._generatedFiles;
            entry = files.".kiro/agents/reviewer.json";
          in
            entry.format
            == "json"
            && entry.content.text == expected
            && !(files ? ".kiro/agents/reviewer.md");
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
          && !(emitted ? welcomeMessage)
          && !(rule ? match)
          && !(rule ? exclude)
          && resource.source == "file:///docs"
          && !(resource ? include)
          && !(resource ? exclude)
          && !(resource ? name)
      );

      # Enabled optional text must carry content. Force the typed agent record so
      # the shared scalar text-source validation runs during module evaluation.
      module-kiro-typed-agent-enabled-empty-welcome-message-rejected = mkTest "kiro-typed-agent-enabled-empty-welcome-message-rejected" (
        let
          attempt = builtins.tryEval (let
            result = evalHm {
              ai.kiro = {
                cli.enable = true;
                native.agents.empty-welcome.welcomeMessage.enable = true;
              };
            };
          in
            builtins.deepSeq result.config.ai.kiro.native.agents.empty-welcome.welcomeMessage true);
        in
          !attempt.success
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

      # Path-valued agent entries enter the generated JSON tree on both backends.
      module-kiro-path-agent-both-backends = mkTest "kiro-path-agent-both-backends" (
        let
          mod = {
            ai.kiro = {
              cli.enable = true;
              agents.from-file = ./fixtures/kiro-agent-raw.json;
            };
          };
          hmEntry = (evalHm mod).config.home.file.".kiro/agents/from-file.json";
          devenvEntry = (evalDevenv mod).config.files.".kiro/agents/from-file.json";
          # The generated tree preserves the JSON document on both backends.
          resolves = e:
            fromGeneratedTree ".kiro/agents/from-file.json" e
            && builtins.fromJSON (builtins.readFile e.source)
            == builtins.fromJSON (builtins.readFile ./fixtures/kiro-agent-raw.json);
        in
          resolves hmEntry && resolves devenvEntry
      );

      # A store-path string is also file content, not literal JSON text.
      module-kiro-store-string-agent-both-backends = mkTest "kiro-store-string-agent-both-backends" (
        let
          storeString = "${./fixtures/kiro-agent-raw.json}";
          mod = {
            ai.kiro = {
              cli.enable = true;
              agents.store-string = storeString;
            };
          };
          hmEntry = (evalHm mod).config.home.file.".kiro/agents/store-string.json";
          devenvEntry = (evalDevenv mod).config.files.".kiro/agents/store-string.json";
          resolves = e:
            fromGeneratedTree ".kiro/agents/store-string.json" e
            && builtins.fromJSON (builtins.readFile e.source)
            == builtins.fromJSON (builtins.readFile storeString);
        in
          resolves hmEntry && resolves devenvEntry
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
            && files ? ".kiro/agents/reviewer.json"
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

      # HM: hook JSON files written under configDir/hooks/.
      module-kiro-hm-writes-hook-files = mkTest "kiro-hm-writes-hook-files" (
        let
          result = evalHm {
            ai.kiro = {
              cli.enable = true;
              hooksJson.pre-commit = ''{"event": "pre-commit"}'';
            };
          };
          hookUnits = hookFiles result;
        in
          # The unit ADDRESS is exact now, not a substring of a script: a body
          # that happens to mention a name proves nothing about what it wrote.
          builtins.attrNames hookUnits
          == ["pre-commit.json"]
          && lib.hasInfix ''"event": "pre-commit"'' (hookInput result "pre-commit")
          && fromGeneratedTree ".kiro/hooks/pre-commit.json" hookUnits."pre-commit.json"
      );

      # HM: a TYPED hook record lowers to the correct v3 envelope JSON. name = attr
      # key; null optionals dropped; action nulls dropped.
      module-kiro-hooks-typed-hm-emits-envelope = mkTest "kiro-hooks-typed-hm-emits-envelope" (
        let
          result = evalHm {
            ai.kiro = {
              cli.enable = true;
              hooks.lint = {
                trigger = "PostToolUse";
                matcher = "fs_write";
                action.command = "just lint";
                timeout = 30;
              };
            };
          };
          t = hookInput result "lint";
        in
          lib.hasInfix ''"version":"v1"'' t
          && lib.hasInfix ''"name":"lint"'' t
          && lib.hasInfix ''"trigger":"PostToolUse"'' t
          && lib.hasInfix ''"matcher":"fs_write"'' t
          && lib.hasInfix ''"type":"command"'' t
          && lib.hasInfix ''"command":"just lint"'' t
          && lib.hasInfix ''"timeout":30'' t
          # `enabled`/`description` were null → omitted.
          && !(lib.hasInfix ''"enabled"'' t)
          && !(lib.hasInfix ''"description"'' t)
      );

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

      # HM: S1 — an `action.command` package coerces to its getExe store path so
      # companion files ride the closure at an absolute, cwd-independent path.
      module-kiro-hooks-command-accepts-package = mkTest "kiro-hooks-command-accepts-package" (
        let
          result = evalHm {
            ai.kiro = {
              cli.enable = true;
              hooks.fmt = {
                trigger = "PostToolUse";
                action.command = pkgs.hello;
              };
            };
          };
          t = hookInput result "fmt";
        in
          lib.hasInfix ''"command":"/nix/store'' t && lib.hasInfix "/bin/hello" t
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
          result.config.ai.kiro.hooks.probe.action.command
          == "${probe}/bin/kiro-hook-probe"
          && lib.hasInfix ''"command":"${builtins.unsafeDiscardStringContext probe.outPath}/bin/kiro-hook-probe"'' (builtins.unsafeDiscardStringContext t)
      );

      module-kiro-hooks-typed-devenv-installs = mkTest "kiro-hooks-typed-devenv-installs" (
        let
          cfg = {
            ai.kiro = {
              cli.enable = true;
              hooks.lint = {
                trigger = "PostToolUse";
                action.command = "just lint";
              };
            };
          };
          dv = evalDevenv cfg;
          hmTarget = hookFiles (evalHm cfg);
          dvTarget = hookFiles dv;
        in
          lib.hasInfix ''"trigger":"PostToolUse"'' (hookInput (evalHm cfg) "lint")
          && fromGeneratedTree ".kiro/hooks/lint.json" hmTarget."lint.json"
          && fromGeneratedTree ".kiro/hooks/lint.json" dvTarget."lint.json"
          # The two backends build separate trees from the same hook input.
          && hookInput dv "lint" == hookInput (evalHm cfg) "lint"
          && !(dv.config.files ? ".kiro/hooks/lint.json")
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
          hookBody = file: builtins.unsafeDiscardStringContext (hookInput (evalHm cfg) file);
          coText = hookBody "kiro-memory";
          co = builtins.fromJSON coText;
          soloText = hookBody "solo";
          dvUnits = hookFiles (evalDevenv cfg);
        in
          # both co-located records land in ONE kiro-memory.json envelope
          co.version
          == "v1"
          && builtins.length co.hooks == 2
          && lib.any (h: h.name == "mem-stop" && h.trigger == "Stop") co.hooks
          && lib.any (h: h.name == "mem-recall" && h.trigger == "UserPromptSubmit") co.hooks
          # the Nix-only `file` grouping key is stripped from every emitted hook object
          && !(lib.any (h: h ? file) co.hooks)
          && !(lib.hasInfix ''"file"'' coText)
          # a record without `file` keeps its own <name>.json (back-compat)
          && lib.hasInfix ''"name":"solo"'' soloText
          # the co-located records do NOT also emit their own per-record files
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

      # Hardening (PR #433 review): an unsafe hook name (path separator) fails the
      # file-name charset assertion before it can be interpolated into a
      # hooks-dir path. `<name>.json` matches the charset exactly when `<name>`
      # does, so the file-name assertion is the one that says so.
      module-kiro-hooks-rejects-unsafe-name = mkTest "kiro-hooks-rejects-unsafe-name" (
        let
          ev = evalHm {
            ai.kiro = {
              cli.enable = true;
              hooksJson."../evil" = builtins.toJSON {
                version = "v1";
                hooks = [];
              };
            };
          };
          nameAsserts =
            builtins.filter (a: lib.hasInfix "hook file names must match" a.message)
            ev.config.assertions;
        in
          nameAsserts != [] && (builtins.head nameAsserts).assertion == false
      );

      # A safe hook name passes the same assertion (assertion == true).
      module-kiro-hooks-accepts-safe-name = mkTest "kiro-hooks-accepts-safe-name" (
        let
          ev = evalHm {
            ai.kiro = {
              cli.enable = true;
              hooksJson."kiro-memory.pre_1" = builtins.toJSON {
                version = "v1";
                hooks = [];
              };
            };
          };
          nameAsserts =
            builtins.filter (a: lib.hasInfix "hook file names must match" a.message)
            ev.config.assertions;
        in
          nameAsserts != [] && (builtins.head nameAsserts).assertion == true
      );

      # Devenv: mcp.json write — real-file task delivery (no files.*
      # symlink), anchored to $DEVENV_ROOT.
      module-kiro-devenv-writes-mcp-json = mkTest "kiro-devenv-writes-mcp-json" (
        let
          result = evalDevenv {
            ai.kiro.cli.enable = true;
            ai.mcpServers.test-server = {
              type = "stdio";
              package = pkgs.hello;
              command = "hello";
            };
          };
          target = mcpFile result;
        in
          target.method
          == "ro"
          && target.content.run != null
          && (mcpFile result).mode == "0444"
          # anchored to the project root without a `cd` in the task body
          && !(result.config.files ? ".kiro/settings/mcp.json")
      );

      # Devenv: environment variables are baked into the launcher, not exported
      # into the project shell (which is what the old `env` blob did).
      module-kiro-devenv-env-wrapper-populated = let
        result = evalDevenv {
          ai.kiro = {
            cli = {
              enable = true;
              environmentVariables.KIRO_LOG_LEVEL = "debug";
            };
          };
        };
      in
        mkWrapperGrepTest {
          name = "kiro-devenv-env-wrapper-populated";
          package = builtins.head result.config.packages;
          bin = "kiro-cli";
          needles = ["KIRO_LOG_LEVEL" "debug"];
        };

      # Devenv: settings/cli.json is a read-only copy of the flattened workspace
      # settings, written only when something is declared.
      module-kiro-devenv-writes-settings-json = mkTest "kiro-devenv-writes-settings-json" (
        let
          result = evalDevenv {
            ai.kiro = {
              cli.enable = true;
              # Workspace-overridable on purpose: `telemetry.enabled` used to stand
              # here, and the workspace-allowlist guard now (correctly) rejects it,
              # which would leave this exercising a config the module declares
              # invalid. The subject of the test — that settings reach the file at
              # all — is unchanged.
              cli.native.settings.chat.enableTangentMode = true;
            };
          };
        in
          kiroCliSettings result
          == {"chat.enableTangentMode" = true;}
          && result.config.ai.files.".kiro/settings/cli.json".method == "ro"
          && !(result.config.files ? ".kiro/settings/cli.json")
          && !((evalDevenv {ai.kiro.cli.enable = true;}).config.ai.files ? ".kiro/settings/cli.json")
      );

      # Devenv: Kiro context joins the shared repository-root AGENTS.md.
      module-kiro-devenv-writes-context = mkTest "kiro-devenv-writes-context" (
        let
          result = evalDevenv {
            ai.kiro = {
              cli.enable = true;
              context.text = "Project conventions go here.";
            };
          };
        in
          fromGeneratedTree "AGENTS.md" (deliveredFiles result.config)."AGENTS.md"
          && lib.hasInfix "Project conventions" (markdownInput result "AGENTS.md").text
          && !((kiroSteeringContent result) ? "AGENTS.md")
      );

      # Devenv: top-level ai.context fans to kiro when per-CLI unset.
      module-kiro-devenv-top-level-context-fallback = mkTest "kiro-devenv-top-level-context-fallback" (
        let
          result = evalDevenv {
            ai.kiro.cli.enable = true;
            ai.context.text = "Top-level context flows everywhere.";
          };
        in
          fromGeneratedTree "AGENTS.md" (deliveredFiles result.config)."AGENTS.md"
          && lib.hasInfix "Top-level context" (markdownInput result "AGENTS.md").text
      );

      # Devenv: agent files written.
      module-kiro-devenv-writes-agent-files = mkTest "kiro-devenv-writes-agent-files" (
        let
          result = evalDevenv {
            ai.kiro = {
              cli.enable = true;
              agents.reviewer = ''{"role": "reviewer"}'';
            };
          };
          agentFile = result.config.files.".kiro/agents/reviewer.json" or null;
        in
          agentFile
          != null
          && lib.hasInfix "reviewer" (builtins.readFile agentFile.source)
      );

      # Devenv: hook files written as REAL files by the materialize task (kiro v3
      # does not discover symlinked hooks, so devenv `files.*` symlinks are wrong
      # here — the task writes a plain `.kiro/hooks/<name>.json`).
      module-kiro-devenv-writes-hook-files = mkTest "kiro-devenv-writes-hook-files" (
        let
          result = evalDevenv {
            ai.kiro = {
              cli.enable = true;
              hooksJson.pre-commit = ''{"event": "pre-commit"}'';
            };
          };
          target = hookFiles result;
        in
          builtins.attrNames target
          == ["pre-commit.json"]
          && lib.hasInfix ''{"event": "pre-commit"}'' (hookInput result "pre-commit")
          && fromGeneratedTree ".kiro/hooks/pre-commit.json" target."pre-commit.json"
          # anchored to the project root without a `cd`: the task runs in the
          # caller's cwd (direnv activates in subdirectories) and every path is
          # resolved against the exported root
          # not a devenv `files.*` symlink
          && !(result.config.files ? ".kiro/hooks/pre-commit.json")
        # the write is ordered before shell entry, and after devenv's own
        # files cleanup (same edge contract as the steering task)
      );

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
          builtins.attrNames target
          == ["sample.json"]
          && lib.hasInfix "hooks-dir-sample" (hookInput result "sample")
          # HM parity — the same input and ledger reach separate generated trees.
          && builtins.attrNames hmTarget == builtins.attrNames target
          && hookInput (evalHm cfg) "sample" == hookInput result "sample"
          && fromGeneratedTree ".kiro/hooks/sample.json" hmTarget."sample.json"
          && fromGeneratedTree ".kiro/hooks/sample.json" target."sample.json"
          # anchored to the project root without a `cd`
          # dropped: the subdirectory and the non-`.json` sibling are ignored
          && !(target ? "nested")
          && !(target ? "inner.json")
          && !(target ? "ignore-me.txt")
          # real files, not devenv `files.*` symlinks
          && !(lib.any (n: lib.hasPrefix ".kiro/hooks/" n) (lib.attrNames result.config.files))
      );

      module-kiro-hooks-dir-rejects-unsafe-filename = mkTest "kiro-hooks-dir-rejects-unsafe-filename" (
        let
          ev = evalHm {
            ai.kiro = {
              cli.enable = true;
              hooksDir = ./fixtures/kiro-hooks-dir-unsafe;
            };
          };
          nameAsserts =
            builtins.filter (a: lib.hasInfix "hook file names must match" a.message)
            ev.config.assertions;
        in
          nameAsserts != [] && (builtins.head nameAsserts).assertion == false
      );

      # ── Kiro steering through ai.kiro.files ─────────────────────────────

      # Two generators producing the same target with divergent whole entries at
      # the same priority must fail. A rule named "AGENTS" and the default context
      # filename deliberately collide here.
      module-kiro-steering-collision-errors = mkTest "kiro-steering-collision-errors" (
        let
          attempt = builtins.tryEval (
            let
              ev = evalHm {
                ai.kiro = {
                  cli.enable = true;
                  context.text = "CONTEXT-COLLIDER.";
                  rules.AGENTS.text = "RULE-COLLIDER.";
                };
              };
            in
              builtins.seq ev.config.ai.kiro._generatedFiles.".kiro/steering/AGENTS.md".content.text true
          );
        in
          !attempt.success
      );

      # Ungated declarations drain even an owner disabled at first upgrade.
      module-kiro-steering-legacy-copies-still-prune = mkTest "kiro-steering-legacy-copies-still-prune" (
        lib.all (evaluate:
          lib.all (enable: let
            inherit ((evaluate {ai.kiro.cli.enable = enable;})) config;
            legacy = {
              codec = "dir";
              ledger = "materialize/kiro-steering.manifest";
              path = ".kiro/steering";
            };
          in
            lib.elem legacy config.ai.kiro.legacyLedgers
            && lib.elem legacy config.ai.legacyLedgers
            && (enable || config.ai.kiro.files == {})) [false true]) [evalHm evalDevenv]
      );

      # Conditional steering is a link on Home Manager and a read-only copy on
      # devenv, where the engine owns only its declared files, so a
      # developer's own steering beside them survives. Unscoped devenv content
      # still goes to the shared AGENTS.md owner.
      module-kiro-steering-uses-runtime-file-sinks = mkTest "kiro-steering-uses-runtime-file-sinks" (
        let
          config = {
            ai.kiro = {
              cli.enable = true;
              context.text = "CONTEXT-TOKEN.";
              rules.enter-test = {
                matcher = ["src/**"];
                text = "ENTER-TEST-TOKEN.";
              };
            };
          };
          hm = evalHm config;
          dv = evalDevenv config;
        in
          fromGeneratedTree ".kiro/steering/enter-test.md" hm.config.home.file.".kiro/steering/enter-test.md"
          && (markdownInput hm ".kiro/steering/enter-test.md").text
          == hm.config.ai.kiro._generatedFiles.".kiro/steering/enter-test.md".content.text
          && fromGeneratedTree ".kiro/steering/AGENTS.md" hm.config.home.file.".kiro/steering/AGENTS.md"
          && fromGeneratedTree ".kiro/steering/enter-test.md" (deliveredFiles dv.config).".kiro/steering/enter-test.md"
          && (markdownInput dv ".kiro/steering/enter-test.md").text
          == dv.config.ai.kiro._generatedFiles.".kiro/steering/enter-test.md".content.text
          && lib.hasInfix "CONTEXT-TOKEN." (markdownInput dv "AGENTS.md").text
          && !(dv.config.files ? ".kiro/steering/enter-test.md")
          && dv.config.ai.files.".kiro/steering/enter-test.md".method.devenv == "ro"
          && dv.config.ai.files.".kiro/steering/enter-test.md".mode == null
          && (harness.ownPlan "kiro" "files-apply" dv).targets != []
      );

      # Engine prune precedes native link checks, with and without native files.
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
          lib.elem "ai:link-check" config.tasks."ai:files-prune".before
          && !(config.tasks ? "ai:kiro:materialize-steering")) [{} {"probe.txt".text = "probe";}]
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

      # Kiro HM: top-level ai.rules → a `<name>.md` steering entry with
      # inclusion frontmatter.
      module-kiro-hm-writes-rules-from-top-level = mkTest "kiro-hm-writes-rules-from-top-level" (
        let
          result = evalHm {
            ai.kiro.cli.enable = true;
            ai.rules.testing = {
              matcher = ["**/*.test.*"];
              text = "Write tests for all new features.";
            };
          };
          ruleFile = (kiroSteeringContent result)."testing.md" or null;
        in
          ruleFile
          != null
          && lib.hasInfix "Write tests for all new features" (ruleFile.text or "")
          && lib.hasInfix ''inclusion: "fileMatch"'' (ruleFile.text or "")
      );

      # Root and per-runtime rule entries are keyed pools; the runtime entry
      # atomically replaces a same-key root default.
      module-kiro-hm-rule-runtime-replaces-root = mkTest "kiro-hm-rule-runtime-replaces-root" (
        let
          result = evalHm {
            ai.kiro = {
              cli.enable = true;
              rules.same-name.text = "Per-CLI wins.";
            };
            ai.rules.same-name.text = "Top-level loses.";
          };
          rendered = (kiroSteeringContent result)."same-name.md".text;
        in
          lib.hasInfix "Per-CLI wins." rendered
          && !(lib.hasInfix "Top-level loses." rendered)
      );

      # Devenv parity: Kiro devenv emits ai.rules to steering entries.
      module-kiro-devenv-writes-rules = mkTest "kiro-devenv-writes-rules" (
        let
          result = evalDevenv {
            ai.kiro.cli.enable = true;
            ai.rules.testing = {
              matcher = ["**/*.test.*"];
              text = "Write tests.";
            };
          };
          ruleFile = (kiroSteeringContent result)."testing.md" or null;
        in
          ruleFile
          != null
          && lib.hasInfix "Write tests" (ruleFile.text or "")
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

      # Devenv: top-level ai.environmentVariables fans to the Kiro wrapper.
      module-kiro-devenv-top-level-env-fanout = let
        result = evalDevenv {
          ai.kiro.cli.enable = true;
          ai.environmentVariables.KIRO_DEBUG = "kiro-devenv-fanout-sentinel";
        };
      in
        mkWrapperGrepTest {
          name = "kiro-devenv-top-level-env-fanout";
          package = builtins.head result.config.packages;
          bin = "kiro-cli";
          needles = ["KIRO_DEBUG" "kiro-devenv-fanout-sentinel"];
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

      # Path-only form: `ai.kiro.rulesDir = ./fixtures/kiro-steering;`
      # expands to three steering entries (alpha, beta, gamma). notes.txt
      # is dropped by the default `.md` filter. Keys land at `<name>.md` —
      # no `.md.md` (vacuous-scan negatives inspect the runtime file map).
      module-kiro-rulesdir-path-form = mkTest "kiro-rulesdir-path-form" (
        let
          result = evalHm {
            ai.kiro = {
              cli.enable = true;
              rulesDir = ./fixtures/kiro-steering;
            };
          };
          steering = kiroSteeringContent result;
          hasAlpha = steering ? "alpha.md";
          hasBeta = steering ? "beta.md";
          hasGamma = steering ? "gamma.md";
          # Key is stripped — no `.md.md` name ever emitted.
          noDoubledMd =
            !(lib.any (p: lib.hasSuffix ".md.md" p) (lib.attrNames steering));
          # notes.txt is filtered out (default keeps only `.md`).
          noNotes = !(steering ? "notes.md");
        in
          hasAlpha
          && hasBeta
          && hasGamma
          && noDoubledMd
          && noNotes
      );

      # Submodule form with custom filter (keep only `alpha.md`).
      module-kiro-rulesdir-submodule-filter =
        mkTest "kiro-rulesdir-submodule-filter" (
          let
            result = evalHm {
              ai.kiro = {
                cli.enable = true;
                rulesDir = {
                  path = ./fixtures/kiro-steering;
                  filter = name: name == "alpha.md";
                };
              };
            };
            steering = kiroSteeringContent result;
          in
            steering
      ? "alpha.md"
            && !(steering ? "beta.md")
            && !(steering ? "gamma.md")
        );

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

      # ── sourcePath rollback regression guards ──────────────────────
      # `sourcePath` was introduced in fab4e5c and rolled back in this
      # commit per the ai-factory-collision refactor plan §6 (commit 2).
      # Live-edit is deprecated — devenv covers iteration. `text` is
      # required again; rules always bake into the store with
      # transformer-injected frontmatter.

      # HM: inline rule text still bakes and carries frontmatter in the runtime file
      # entry; the generic sink then preserves that exact entry.
      module-kiro-hm-rule-text-bakes = mkTest "kiro-hm-rule-text-bakes" (
        let
          result = evalHm {
            ai.kiro = {
              cli.enable = true;
              rules.my-rule.text = "Inline content";
            };
          };
          entry = (kiroSteeringContent result)."my-rule.md" or null;
        in
          entry
          != null
          && entry.text != null
          # Unified content records retain the inactive source arm as null.
          && entry.source == null
          && lib.hasInfix "Inline content" entry.text
      );

      # HM: rule.source is read and baked into the materialized entry.
      module-kiro-hm-rule-path-bakes = mkTest "kiro-hm-rule-path-bakes" (
        let
          result = evalHm {
            ai.kiro = {
              cli.enable = true;
              rules.rule-from-path.source = ./fixtures/kiro-steering/alpha.md;
            };
          };
          entry = (kiroSteeringContent result)."rule-from-path.md" or null;
        in
          entry
          != null
          && entry.text != null
          # The source was baked into text; the inactive arm remains null.
          && entry.source == null
          && lib.hasInfix "Alpha steering body" entry.text
      );

      # Negative: `sourcePath` is no longer a known option. Attempting to
      # set it fails module evaluation (tryEval captures the error from
      # strict-evaluating only the target rule's attrs, to avoid a full
      # config-tree walk stack overflow).
      module-kiro-hm-rule-sourcepath-rejected = mkTest "kiro-hm-rule-sourcepath-rejected" (
        let
          attempt = builtins.tryEval (let
            r = evalHm {
              ai.kiro = {
                cli.enable = true;
                rules.my-rule = {
                  text = "body";
                  sourcePath = "/abs/path/to/my-rule.md";
                };
              };
            };
          in
            builtins.deepSeq r.config.ai.kiro.rules.my-rule true);
        in
          !attempt.success
      );
    }
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
      # A detectable custom FHS package without the payload-composition seam would
      # recreate #956. Reject it rather than silently leaving trust injection in an
      # outer wrapper that launcher dispatch cannot reach.
      module-kiro-trust-rejects-fhs-package-without-payload-seam = mkTest "kiro-trust-rejects-fhs-package-without-payload-seam" (
        let
          customFhsPackage = pkgs.hello.overrideAttrs (attrs: {
            passthru = (attrs.passthru or {}) // {unwrapped = pkgs.hello;};
          });
          ev = evalDevenv {
            ai.kiro = {
              cli = {
                enable = true;
                package = customFhsPackage;
                trustedMcpTools = ["fs_read"];
              };
            };
          };
          asserts =
            builtins.filter (a: lib.hasInfix "passthru.withFhsPayload" a.message)
            ev.config.assertions;
        in
          asserts != [] && (builtins.head asserts).assertion == false
      );

      # Assertions inspect the resolved rollout variant, not merely cfg.cli.package.
      # A custom factory that drops the FHS passthru contract must fail by name
      # before wrapping can silently retain the sandbox or lose trust injection.
      module-kiro-trust-rejects-rollout-variant-without-payload-seam = mkTest "kiro-trust-rejects-rollout-variant-without-payload-seam" (
        let
          customFhsPackage = pkgs.hello.overrideAttrs (attrs: {
            passthru =
              (attrs.passthru or {})
              // {
                kiroFhsSandbox = true;
                unwrapped = pkgs.hello;
                withFhsPayload = _: pkgs.hello;
                withRolloutFeatures = _: pkgs.hello;
              };
          });
          ev = evalHm {
            ai.kiro = {
              cli = {
                enable = true;
                package = customFhsPackage;
                trustedMcpTools = ["fs_read"];
                features.background_execution.enable = true;
                v3 = true;
              };
            };
          };
          asserts =
            builtins.filter (a: lib.hasInfix "passthru.withFhsPayload" a.message)
            ev.config.assertions;
        in
          asserts != [] && (builtins.head asserts).assertion == false
      );
    };
}
