# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode sembleignore
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) checkRows claudeMcpPath claudeMcpServers claudeSettings deliveredMarkdown evalDevenv evalDevenvModules evalHm evalHmModules fromGeneratedTree markdownInput mkTest ownPlan ownedDocument rejectsChange;
  inherit (import ./helpers.nix {inherit lib;}) claudeAssertionFails claudeAssertionsPass claudeKnownKeysCfg claudeNestedTypoCfg claudeSettingsWarnings handlerCommands hasGuardHook;
  unpinDocument = ownedDocument "claude" ".claude.json";
  # A contract both backends deliver alike, stated once and evaluated on each:
  # `eval` evaluates a configuration (`evalModules` a list of modules), `files`
  # reads its symlink sink, `mcpPath` is where Claude's MCP servers land, and
  # `upstreamEnable` is the enable option of the backend's own Claude module.
  backends = {
    devenv = {
      eval = evalDevenv;
      evalModules = evalDevenvModules;
      files = config: config.files;
      mcpPath = claudeMcpPath "devenv";
      mcpServers = claudeMcpServers "devenv";
      upstreamEnable = ["claude" "code" "enable"];
    };
    hm = {
      eval = evalHm;
      evalModules = evalHmModules;
      files = config: config.home.file;
      mcpPath = claudeMcpPath "hm";
      mcpServers = claudeMcpServers "hm";
      upstreamEnable = ["programs" "claude-code" "enable"];
    };
  };
  # `ai.claude` beside a stand-in for the backend's own Claude module, whose
  # enable option is set to `upstream`.
  evalWithUpstream = arm: upstream:
    arm.evalModules [
      {options = lib.setAttrByPath arm.upstreamEnable (lib.mkEnableOption "the upstream Claude module");}
      {config = lib.recursiveUpdate {ai.claude.enable = true;} (lib.setAttrByPath arm.upstreamEnable upstream);}
    ];
  perBackend = name: test:
    lib.mapAttrs' (backend: arm:
      lib.nameValuePair "module-claude-${backend}-${name}"
      (mkTest "claude-${backend}-${name}" (test (arm // {inherit backend;}))))
    backends;
  # The settings.json document one configuration declares, on one backend.
  settingsOf = arm: config: claudeSettings (arm.eval config);
  families = {
    # ── Per-backend families ─────────────────────────────────────────
    # Both backends write ONE settings.json document the same way, so each of
    # these contracts is stated once and evaluated on each backend.
    checks = lib.mergeAttrsList [
      # Both modules would write Claude's files. Importing the upstream
      # module alone must not trigger the conflict when its enable is off.
      (perBackend "upstream-module-conflict" (arm:
        checkRows "upstream Claude module conflict" {
          "both enabled names the exact upstream option to disable" =
            claudeAssertionFails
            "ai.claude.enable and ${lib.concatStringsSep "." arm.upstreamEnable} cannot both be on: each writes Claude's files, and they cannot share them. Disable one of the two."
            (evalWithUpstream arm true);
          "upstream disabled leaves Claude assertions passing" = claudeAssertionsPass (evalWithUpstream arm false);
        }))

      # Exercise the real typed merge with one rejected value per enum, then
      # check that the chosen TUI renderer survives delivery on each backend.
      (perBackend "settings-typed-enums" (arm: let
        native = key: value: {
          ai.claude = {
            enable = true;
            native.settings.${key} = value;
          };
        };
        enum = key: valid: invalid:
          rejectsChange (value: (arm.eval (native key value)).config.ai.claude.native.settings.${key}) {
            inherit valid invalid;
            expected = valid;
          };
        settings = settingsOf arm {
          ai.claude = {
            enable = true;
            native.settings.tui = "fullscreen";
          };
        };
      in
        checkRows "typed Claude settings" {
          "effortLevel rejects session-only max" = enum "effortLevel" "xhigh" "max";
          "tui rejects the unknown renderer curses" = enum "tui" "fullscreen" "curses";
          "tui writes the chosen fullscreen renderer" = settings.tui == "fullscreen";
        }))

      # Freeform environment keys survive delivery when the consumer also
      # overrides the package's updater default. The HM coexistence check
      # below pins nested permissions in the HM settings document.
      (perBackend "settings-reach-document" (arm: let
        checkPermissions = arm.backend == "devenv";
        settings = settingsOf arm {
          ai.claude = {
            enable = true;
            native.settings =
              {
                env = {
                  DISABLE_AUTOUPDATER = "0";
                  FOO = "bar";
                };
              }
              // lib.optionalAttrs checkPermissions {permissions.allow = ["Read"];};
          };
        };
      in
        checkRows "Claude settings document" (
          {"freeform environment entries survive merging with package defaults" = settings.env.FOO == "bar";}
          // lib.optionalAttrs checkPermissions {
            "nested permission leaves are not dropped" = settings.permissions.allow == ["Read"];
          }
        )))

      # Attribution: `false` coerces to "" at the type layer (disables the
      # commit trailer) and survives the null-filter (filterNulls keeps "").
      (perBackend "attribution-false-disables" (arm:
        (settingsOf arm {
          ai.claude = {
            enable = true;
            native.settings.attribution.commit = false;
          };
        }).attribution.commit
        == ""))

      # Attribution: a custom string passes through unchanged.
      (perBackend "attribution-string-written" (arm:
        (settingsOf arm {
          ai.claude = {
            enable = true;
            native.settings.attribution.pr = "Reviewed-by: me";
          };
        }).attribution.pr
        == "Reviewed-by: me"))

      # Attribution: `true` coerces to null -> filtered; the attribution block
      # collapses to empty and is dropped entirely (Claude keeps its defaults).
      (perBackend "attribution-true-filtered" (arm:
        !(settingsOf arm {
          ai.claude = {
            enable = true;
            native.settings.attribution.commit = true;
          };
        } ? attribution)))

      # `false` survives the null-filter (filterNulls drops null, keeps false).
      (perBackend "workflow-keyword-trigger-false-written" (arm: let
        settings = settingsOf arm {
          ai.claude = {
            enable = true;
            native.settings.workflowKeywordTriggerEnabled = false;
          };
        };
      in
        !settings.workflowKeywordTriggerEnabled))

      # Meta option: ultracodeOnLaunch writes the `ultracode` key
      # and the `enableWorkflows` master toggle — and ONLY those: not effortLevel
      # (ultracode keeps the session effort) nor workflowKeywordTriggerEnabled (orthogonal
      # per-turn key).
      (perBackend "ultracode-on-launch-writes-settings" (arm: let
        settings = settingsOf arm {
          ai.claude = {
            enable = true;
            ultracodeOnLaunch = true;
          };
        };
      in
        settings.ultracode
        && settings.enableWorkflows
        && !(settings ? effortLevel)
        && !(settings ? workflowKeywordTriggerEnabled)))

      # The meta option writes at mkDefault, so an explicit
      # native.settings.ultracode = false wins and survives the null-filter.
      (perBackend "ultracode-on-launch-explicit-false-wins" (arm: let
        settings = settingsOf arm {
          ai.claude = {
            enable = true;
            ultracodeOnLaunch = true;
            native.settings.ultracode = false;
          };
        };
      in
        !settings.ultracode))

      # Soft-enum model: an arbitrary (unknown) id is accepted and written.
      (perBackend "model-soft-enum-accepts-arbitrary" (arm:
        (settingsOf arm {
          ai.claude = {
            enable = true;
            native.settings.model = "some-future-model";
          };
        }).model
        == "some-future-model"))

      # The typed ai.claude.hooks event map lowers into settings.json.hooks.
      # Without guard opt-in, only the consumer hook may be delivered.
      (perBackend "hooks-lower-to-settings" (arm: let
        settings = settingsOf arm {
          ai.claude = {
            enable = true;
            hooks.PreToolUse = [
              {
                matcher = "Bash";
                hooks = [{command = "validate";}];
              }
            ];
          };
        };
      in
        map (block: {
          inherit (block) matcher;
          hooks = map (handler: {inherit (handler) command type;}) block.hooks;
        })
        settings.hooks.PreToolUse
        == [
          {
            matcher = "Bash";
            hooks = [
              {
                command = "validate";
                type = "command";
              }
            ];
          }
        ]))

      # The legacy `native.settings.hooks` escape hatch lowers verbatim into
      # settings.json.hooks, composing with the typed event map through the
      # per-event join in mkClaude.nix (zipAttrsWith concatLists).
      (perBackend "settings-hooks-escape-hatch" (arm: let
        hooks =
          (settingsOf arm {
            ai.claude = {
              enable = true;
              hooks.PreToolUse = [{hooks = [{command = "typed";}];}];
              native.settings.hooks.PreToolUse = [{matcher = "Bash";}];
            };
          })
        .hooks
        .PreToolUse;
      in
        lib.any (block: (block.matcher or null) == "Bash") hooks
        && handlerCommands (lib.filter (block: block ? hooks) hooks) == ["typed"]))

      # hookScripts land as executable `.claude/hooks/<name>` links; they are
      # never merged into settings.json, which keeps its own hooks.
      (perBackend "hookscripts-land-as-executable-files" (arm: let
        result = arm.eval {
          ai.claude = {
            enable = true;
            hookScripts.my-hook = "#!/usr/bin/env bash\nexit 0\n";
            native.settings.hooks.from-settings = [{matcher = "X";}];
          };
        };
        file = (arm.files result.config).".claude/hooks/my-hook" or {};
      in
        deliveredMarkdown result ".claude/hooks/my-hook"
        == "#!/usr/bin/env bash\nexit 0\n"
        && file.executable
        && (claudeSettings result).hooks ? from-settings))

      # Commands and output styles are static Markdown on both backends,
      # including path-backed inputs. Their delivered files come from the tree.
      (perBackend "commands-and-output-styles-land-as-files" (arm: let
        result = arm.eval {
          ai.claude = {
            enable = true;
            commands.fix-issue = "# Fix issue\n\nSteps…";
            outputStyles = {
              concise = "Keep answers under 3 sentences.";
              linked = ./fixtures/claude-agents/agent-one.md;
            };
          };
        };
        files = arm.files result.config;
      in
        fromGeneratedTree ".claude/commands/fix-issue.md" files.".claude/commands/fix-issue.md"
        && fromGeneratedTree ".claude/output-styles/concise.md" files.".claude/output-styles/concise.md"
        && fromGeneratedTree ".claude/output-styles/linked.md" files.".claude/output-styles/linked.md"
        && (markdownInput result ".claude/commands/fix-issue.md").text == "# Fix issue\n\nSteps…"
        && (markdownInput result ".claude/output-styles/concise.md").text == "Keep answers under 3 sentences."
        && (markdownInput result ".claude/output-styles/linked.md").source == ./fixtures/claude-agents/agent-one.md))

      # A marketplace is announced in settings.json on both backends, and
      # Claude registers it from there.
      (perBackend "marketplaces-land-in-settings" (arm: let
        src = ../../stacked-workflows/skills/stack-fix;
        result = arm.eval {
          ai.claude = {
            enable = true;
            marketplaces.my-shelf = src;
          };
        };
      in
        (claudeSettings result).extraKnownMarketplaces.my-shelf
        == {
          source = {
            source = "directory";
            path = "${src}";
          };
        }))

      # Settings and MCP servers are configuration: Nix owns each whole file
      # and the backend links it read-only. The engine copies neither and no
      # writer reconciles either, so an in-app change does not persist, and
      # disabling Claude drops the link.
      (perBackend "settings-and-mcp-are-read-only-links" (
        arm: let
          off = arm.eval {
            ai.claude = {
              enable = false;
              mcpServers.remote = {
                type = "http";
                url = "https://example.invalid/mcp";
              };
              native.settings.effortLevel = "low";
            };
          };
          paths = [".claude/settings.json" arm.mcpPath];
        in
          lib.all (path: !((arm.files off.config) ? ${path})) paths
      ))

      # Use a real server name so renderServer's package and mode branches run.
      # Pin the mode-specific command on both sinks;
      # checks/mcp-timeout/module-eval.nix pins the full packaged stdio record
      # on both backends, including env, through the same merged server renderer.
      (perBackend "mcp-servers-rendered" (arm: let
        evaluated = arm.eval {
          ai.claude = {
            enable = true;
            mcpServers.context7-mcp.package = pkgs.hello;
          };
        };
        servers = arm.mcpServers evaluated;
        rendered = servers.context7-mcp;
      in
        checkRows "Claude MCP rendering" {
          "mode supplies the binary name under the caller's package path" = rendered.command == "${pkgs.hello}/bin/context7-mcp";
        }))

      # Opt-in places exactly one guard on Write/Edit without clobbering
      # existing hooks. The script's path test is the other half of the filter.
      (perBackend "memory-collision-guard" (arm: let
        settings = withConsumer:
          settingsOf arm {
            ai.claude =
              {
                enable = true;
                memoryCollisionGuard.enable = true;
              }
              // lib.optionalAttrs withConsumer {
                hooks.PreToolUse = [
                  {
                    matcher = "Bash";
                    hooks = [{command = "consumer-hook";}];
                  }
                ];
              };
          };
        onlyGuard = (settings false).hooks.PreToolUse;
        together = (settings true).hooks.PreToolUse;
        isGuard = block: hasGuardHook [block];
      in
        checkRows "Claude memory collision guard" {
          "opt-in alone adds exactly one guard block restricted to Write or Edit" =
            map (block: block.matcher) onlyGuard == ["Write|Edit"] && hasGuardHook onlyGuard;
          "opt-in beside a consumer hook keeps the guard and one copy of the consumer handler" =
            builtins.filter isGuard together
            == onlyGuard
            && handlerCommands (builtins.filter (block: !(isGuard block)) together) == ["consumer-hook"];
        }))

      # A spelling diagnostic must remain advisory: Claude tolerates and
      # ignores an unknown key, and consumers can explicitly allowlist it.
      (perBackend "unrecognized-settings" (arm: let
        known = arm.eval claudeKnownKeysCfg;
        typo = arm.eval claudeNestedTypoCfg;
        allowlisted = arm.eval (lib.recursiveUpdate claudeNestedTypoCfg {
          ai.claude.allowUnrecognizedSettings = ["permissions.alow"];
        });
        staleAllowlist = arm.eval {
          ai.claude = {
            enable = true;
            allowUnrecognizedSettings = ["ultracode"];
          };
        };
        warnsOnce = diagnostic: evaluated: let
          warnings = claudeSettingsWarnings evaluated;
        in
          claudeAssertionsPass evaluated && builtins.length warnings == 1 && diagnostic (builtins.head warnings);
        passesQuietly = evaluated: claudeAssertionsPass evaluated && claudeSettingsWarnings evaluated == [];
        keepsUnknownKey = evaluated: (claudeSettings evaluated).permissions.alow == ["Read"];
      in
        checkRows "Claude unrecognized settings" {
          "allowlisting the exact unknown leaf suppresses its warning without dropping the setting" = passesQuietly allowlisted && keepsUnknownKey allowlisted;
          "known keys including the open containers pass without warnings" = passesQuietly known;
          "nested typo warns with the corrected path rather than refusing or stripping the key" =
            warnsOnce (warning:
              lib.hasInfix "ai.claude.native.settings.permissions.alow" warning
              && lib.hasInfix "did you mean `ai.claude.native.settings.permissions.allow`" warning)
            typo
            && keepsUnknownKey typo;
          "stale allowlist entry for a now-known key warns rather than masking typos forever" =
            warnsOnce (lib.hasInfix "ai.claude.allowUnrecognizedSettings: stale allowlist entry `ultracode`") staleAllowlist;
        }))

      # An external installation keeps its own updater policy, and with
      # nothing else declared no document is written to shadow a project's own.
      (perBackend "settings-package-null-writes-no-file" (arm:
        !((arm.files
          (arm.eval {
            ai.claude = {
              enable = true;
              package = null;
            };
            ai.gitSshConfigWorkaround = false;
          }).config)
          ? ".claude/settings.json")))
    ];
  };
in {
  checks =
    {
      # With no consumer settings, the updater default owns the document.
      # Exact equality catches leaked null settings, default launch flags, or
      # hooks without opt-in. Disable the SSH workaround to isolate the default.
      module-claude-hm-settings-default-only-document = mkTest "claude-hm-settings-default-only-document" (
        claudeSettings (evalHm {
          ai.claude.enable = true;
          ai.gitSshConfigWorkaround = false;
        })
        == {
          "$schema" = "https://json.schemastore.org/claude-code-settings.json";
          env.DISABLE_AUTOUPDATER = "1";
        }
      );

      module-claude-shared-rule-emits-native-file = mkTest "claude-shared-rule-emits-native-file" (
        let
          evaluated = evalHm {
            ai = {
              claude.enable = true;
              rules.search = {
                text = "Always use rg instead of grep.";
                description = "Grep replacement";
              };
            };
          };
          rule = (markdownInput evaluated ".claude/rules/search.md").text;
        in
          lib.hasInfix ''description: "Grep replacement"'' rule
      );

      module-claude-no-guidance-no-file = mkTest "claude-no-guidance-no-file" (
        let
          evaluated = evalHm {ai.claude.enable = true;};
          # With no rules and no context merged, nothing enters the final file map.
        in
          !(evaluated.config.home.file ? ".claude/CLAUDE.md")
      );

      # Claude HM stages context and each keyed rule as generated files before
      # the generic backend sink.
      module-claude-hm-context-and-rules = mkTest "claude-hm-context-and-rules" (
        let
          evaluated = evalHm {
            ai = {
              claude = {
                enable = true;
                context.text = "CONTEXT-BASELINE-TOKEN.";
              };
              rules = {
                named-rule = {
                  text = "NAMED-RULE-BODY-TOKEN.";
                  matcher = ["src/**"];
                };
                unnamed = {
                  text = "UNNAMED-INSTR-TOKEN.";
                  description = "unnamed always-on";
                };
              };
            };
          };
          files = evaluated.config.home.file;
          aggregate = (markdownInput evaluated ".claude/CLAUDE.md").text;
          ruleFile = (markdownInput evaluated ".claude/rules/named-rule.md").text;
        in
          aggregate
          == "CONTEXT-BASELINE-TOKEN."
          && fromGeneratedTree ".claude/rules/named-rule.md" files.".claude/rules/named-rule.md"
          && lib.hasInfix "NAMED-RULE-BODY-TOKEN." ruleFile
          && files ? ".claude/rules/unnamed.md"
      );

      # Claude devenv writes context to `.claude/CLAUDE.md` and keeps every rule in
      # its own native file, without duplicating rule bodies into the context file.
      # N→0 and a disable claim no rule, and the old rules writer's ledger is
      # declared either way, so the copies it wrote drain.
      module-claude-devenv-context-and-rules = mkTest "claude-devenv-context-and-rules" (
        let
          cfg = {
            ai = {
              claude = {
                enable = true;
                context.text = "CONTEXT-BASELINE-TOKEN.";
              };
              rules = {
                named-rule = {
                  text = "NAMED-RULE-BODY-TOKEN.";
                  matcher = ["src/**"];
                };
                unnamed = {
                  text = "UNNAMED-INSTR-TOKEN.";
                  description = "unnamed always-on";
                };
              };
            };
          };
          evaluated = evalDevenv cfg;
          emptied = evalDevenv {ai.claude.enable = true;};
          disabled = evalDevenv (lib.recursiveUpdate cfg {ai.claude.enable = false;});
          bare = evalDevenv {};
          # The old devenv rules writer's ledger is Claude's and reaches the
          # engine's root list even without any Claude configuration.
          ledger = {
            codec = "dir";
            ledger = "materialize/claude-rules.manifest";
            path = ".claude/rules";
          };
          declaresRulesLedger = result: result.config.ai.claude.legacyLedgers == [ledger];
          claimsNoRule = result: !(lib.any (lib.hasPrefix ".claude/rules/") (builtins.attrNames result.config.ai.claims.path));
          composed = (markdownInput evaluated ".claude/CLAUDE.md").text;
          # Project rules are read-only copies, not links: see mkClaude's rules
          # entry. The engine copies each one's file in the generated tree.
          rules = lib.listToAttrs (map (target: lib.nameValuePair target.path target) (ownPlan "claude" "files-apply" evaluated).targets);
          copied = path:
            rules.${path}.method
            == "ro"
            && rules.${path}.format == "markdown"
            && rules.${path}.mode == null
            && rules.${path}.content.source == "${evaluated.config.ai.claude._generatedTree}/${path}";
        in
          lib.hasInfix "CONTEXT-BASELINE-TOKEN." composed
          && !(lib.hasInfix "UNNAMED-INSTR-TOKEN." composed)
          && !(lib.hasInfix "NAMED-RULE-BODY-TOKEN." composed)
          && copied ".claude/rules/named-rule.md"
          && lib.hasInfix "NAMED-RULE-BODY-TOKEN." (markdownInput evaluated ".claude/rules/named-rule.md").text
          && copied ".claude/rules/unnamed.md"
          && builtins.attrNames rules == [".claude/rules/named-rule.md" ".claude/rules/unnamed.md"]
          && !(evaluated.config.files ? ".claude/rules/named-rule.md")
          && claimsNoRule emptied
          && claimsNoRule disabled
          && lib.all declaresRulesLedger [bare disabled emptied evaluated]
          && builtins.elem ledger bare.config.ai.legacyLedgers
      );

      # Both direct Claude backends deliver built Markdown. A long paragraph
      # proves formatting happened before each delivered store file was used.
      module-claude-static-markdown-built-on-both-backends = let
        words = lib.genList (n: "word${toString n}") 60;
        cfg = {
          ai.claude = {
            enable = true;
            context.text = lib.concatStringsSep " " words;
          };
        };
        hm = evalHm cfg;
        devenv = evalDevenv cfg;
        path = ".claude/CLAUDE.md";
        hmFile = hm.config.home.file.${path};
        devenvFile = devenv.config.files.${path};
      in
        assert lib.assertMsg (fromGeneratedTree path hmFile && fromGeneratedTree path devenvFile)
        "claude-static-markdown-built-on-both-backends: context must come from generated trees";
          pkgs.runCommand "module-test-claude-static-markdown-built-on-both-backends" {} ''
            for file in ${hmFile.source} ${devenvFile.source}; do
              [ -z "$(awk 'length > 80' "$file")" ]
              [ "$(grep -c word "$file")" -gt 1 ]
            done
            echo PASS > "$out"
          '';

      # Skills land as links under ~/.claude/skills, a directory's leaves each:
      # one recursive layer-1 entry the engine walks into per-leaf links.
      module-claude-hm-skills-land-as-files = mkTest "claude-hm-skills-land-as-files" (
        let
          src = ../../stacked-workflows/skills/stack-fix;
          result = evalHm {
            ai.claude.enable = true;
            ai.skills.stack-fix = src;
          };
        in
          result.config.home.file.".claude/skills/stack-fix/SKILL.md".source
          == "${src}/SKILL.md"
          && !(result.config.home.file ? ".claude/skills/stack-fix")
      );

      # A consumer's layer-1 entry beats a staged skill: text replaces a
      # single-file skill, and `enable = false` drops a tree's leaves.
      module-claude-hm-skill-consumer-override-wins = mkTest "claude-hm-skill-consumer-override-wins" (
        let
          inherit
            (evalHm {
              ai.claude = {
                enable = true;
                files = {
                  ".claude/skills/probe/SKILL.md".content.text = "mine";
                  ".claude/skills/stack-fix".enable = false;
                };
              };
              ai.skills = {
                probe = ./fixtures/claude-skills/skill-a/SKILL.md;
                stack-fix = ../../stacked-workflows/skills/stack-fix;
              };
            })
            config
            ;
        in
          config.ai.files.".claude/skills/probe/SKILL.md".content._choice
          == "text"
          && config.home.file ? ".claude/skills/probe/SKILL.md"
          && !(lib.any (lib.hasPrefix ".claude/skills/stack-fix/") (builtins.attrNames config.home.file))
      );

      # Shared typed hooks coexist with native permissions in the delivered
      # settings.json.
      module-claude-hm-delivery-lands-surfaces-as-files = mkTest "claude-hm-delivery-lands-surfaces-as-files" (
        let
          result = evalHm {
            ai = {
              claude = {
                agents.probe = "probe agent";
                enable = true;
                hookScripts.probe = "probe script";
                native.settings.permissions.allow = ["Read"];
              };
              hooks.PreToolUse = [{hooks = [{command = "true";}];}];
              mcpServers.probe.command = "probe";
              skills.probe = ./fixtures/claude-skills/skill-a;
            };
          };
          settings = claudeSettings result;
        in
          settings.permissions.allow
          == ["Read"]
          && handlerCommands settings.hooks.PreToolUse == ["true"]
      );

      # Every Claude surface is staged. Each lands where it did: links in
      # the backend's sink, devenv rules as engine copies.
      module-claude-surfaces-are-staged = mkTest "claude-surfaces-are-staged" (
        let
          cfg = {
            ai = {
              claude = {
                agents.probe = "probe agent";
                commands.probe = "probe command";
                enable = true;
                hookScripts.probe = "probe script";
                native.settings.effortLevel = "low";
                outputStyles.probe = "probe style";
              };
              context.text = "probe context";
              mcpServers.probe.command = "probe";
              rules.probe.text = "probe rule";
              skills.probe = ./fixtures/claude-skills/skill-a;
            };
          };
          hm = (evalHm (lib.recursiveUpdate cfg {ai.claude.plugins.my-plugin = ../../stacked-workflows/skills/stack-fix;})).config;
          devenv = (evalDevenv cfg).config;
          shared = [".claude/CLAUDE.md" ".claude/agents/probe.md" ".claude/commands/probe.md" ".claude/hooks/probe" ".claude/output-styles/probe.md" ".claude/rules/probe.md" ".claude/settings.json" ".claude/skills/probe"];
          hmStaged = shared ++ [".claude.json" ".claude/skills/home-manager/.claude-plugin/plugin.json" ".claude/skills/home-manager/.mcp.json" ".claude/skills/my-plugin"];
          devenvStaged = shared ++ [".mcp.json"];
          linked = files: lib.all (path: files ? ${path} || lib.any (lib.hasPrefix "${path}/") (builtins.attrNames files));
        in
          builtins.attrNames hm.ai.claude._generatedFiles
          == lib.sort lib.lessThan hmStaged
          && builtins.attrNames devenv.ai.claude._generatedFiles == lib.sort lib.lessThan devenvStaged
          && linked hm.home.file (lib.remove ".claude.json" hmStaged)
          && linked devenv.files (lib.remove ".claude/rules/probe.md" devenvStaged)
      );

      # Ported from module-delivery-normalized-agent-source-crosses-alone: the
      # normalized pools copy text-source records, and only the winning arm may
      # cross. A `text` beside a winning `source` lands at the same priority,
      # which the record rejects, and computing that priority reads the source.
      module-claude-normalized-agent-source-crosses-alone = mkTest "claude-normalized-agent-source-crosses-alone" (
        let
          source = ./fixtures/claude-skills/skill-a/SKILL.md;
        in
          lib.all (evaluate: let
            inherit
              ((evaluate {
                  ai = {
                    agents.probe = {
                      description = "probe";
                      instructions.source = source;
                    };
                    claude.enable = true;
                  };
                })
                .config
                .ai
                .claude
                .normalized
                .agents
                .probe)
              instructions
              ;
          in
            instructions._sourceWins && instructions.source == source) [evalHm evalDevenv]
      );

      # The personal plugin's manifest names it `hm`, which is the MCP tool
      # namespace (`mcp__plugin_hm_<server>__<tool>`) consumers may have pinned.
      # No manifest at all when the plugin carries no MCP servers.
      module-claude-hm-personal-plugin-manifest-is-hm = mkTest "claude-hm-personal-plugin-manifest-is-hm" (
        let
          manifest = ".claude/skills/home-manager/.claude-plugin/plugin.json";
          withServers =
            (evalHm {
              ai.claude.enable = true;
              ai.mcpServers.probe.command = "probe";
            }).config;
          bare = (evalHm {ai.claude.enable = true;}).config;
        in
          withServers.ai.claude.files.${manifest}.content.value
          == {name = "hm";}
          && !(bare.home.file ? ${manifest})
      );

      # A consumer's own settings leaf beats the leaf the module generates at
      # `mkDefault`, and the rest of the generated document survives it.
      module-claude-hm-consumer-overrides-generated-defaults = mkTest "claude-hm-consumer-overrides-generated-defaults" (
        let
          settings = claudeSettings (evalHm {
            ai = {
              claude = {
                enable = true;
                native.settings.effortLevel = "low";
                ultracodeOnLaunch = true;
              };
              settings.reasoningEffort = "high";
            };
          });
        in
          settings.effortLevel == "low" && settings.enableWorkflows
      );

      # ── Claude launch-effort unpin reconciler ──────────────────────

      # Read the writable engine document: installMethod defaults to "native"
      # with the default launch flag, stages alone, and drops out when null.
      module-claude-hm-install-method = mkTest "claude-hm-install-method" (
        let
          document = native: (unpinDocument (evalHm {ai.claude = {enable = true;} // native;})).value;
          alone = document {native.unpinLaunchEffort = lib.mkForce {};};
          defaults = document {};
          unset = document {native.installMethod = null;};
        in
          alone
          == {installMethod = "native";}
          && defaults.installMethod == "native"
          && defaults.unpinOpus48LaunchEffort
          && !(unset ? installMethod)
          && unset.unpinOpus48LaunchEffort
      );

      # A key set false is still written (re-pins that model deliberately).
      module-claude-hm-unpin-false-key-written = mkTest "claude-hm-unpin-false-key-written" (
        let
          result = evalHm {
            ai.claude.enable = true;
            ai.claude.native.unpinLaunchEffort.unpinOpus48LaunchEffort = false;
          };
        in
          (unpinDocument result).value.unpinOpus48LaunchEffort == false
      );

      # ── Attrs-shape ai.rules / ai.<cli>.rules (unified transformer) ───

      # HM: each plugin lands as ONE directory link at ~/.claude/skills/<key>,
      # never as a tree of leaves: Claude's agents/ and commands/ scanners take
      # regular files only.
      module-claude-hm-plugins-land-as-files = mkTest "claude-hm-plugins-land-as-files" (
        let
          result = evalHm {
            ai.claude = {
              enable = true;
              plugins.my-plugin = ../../stacked-workflows/skills/stack-fix;
            };
          };
          file = result.config.home.file.".claude/skills/my-plugin" or {};
        in
          fromGeneratedTree ".claude/skills/my-plugin" file
          && lib.hasSuffix "-claude-code-plugin-my-plugin" (markdownInput result ".claude/skills/my-plugin").source
      );

      # HM: the ATTRIBUTE NAME — not the source's base name — is the plugin's
      # on-disk directory name and synthesized manifest name. A bare flake-input
      # store path would otherwise yield an unstable `<hash>-source` renamed by
      # every unrelated input bump.
      module-claude-hm-plugins-key-is-directory-name = mkTest "claude-hm-plugins-key-is-directory-name" (
        let
          # A package whose store base name (…-hello-<version>) is nothing like
          # the key, standing in for a flake-input root.
          pluginPkg = pkgs.hello;
          files =
            (evalHm {
              ai.claude = {
                enable = true;
                plugins.remember = pluginPkg;
              };
            }).config.home.file;
          derivedName =
            builtins.unsafeDiscardStringContext (baseNameOf (toString pluginPkg));
        in
          files ? ".claude/skills/remember"
          && !(files ? ".claude/skills/${derivedName}")
      );

      # Every collision would shadow a different owner of ~/.claude/skills.
      # Pin the named owner and the remedy instead of accepting any assertion.
      module-claude-hm-plugin-collisions = mkTest "claude-hm-plugin-collisions" (
        let
          src = ../../stacked-workflows/skills/stack-fix;
          skill = ./fixtures/claude-skills/skill-a/SKILL.md;
          evaluate = extra: evalHm {ai.claude = {enable = true;} // extra;};
          failsWith = message: extra:
            lib.any (a: !a.assertion && a.message == message) (evaluate extra).config.assertions;
          personalSkill = {skills.home-manager = skill;};
          skillConflict = "ai.skills.home-manager (or ai.claude.skills.home-manager) would land at ~/.claude/skills/home-manager, which the home-manager personal plugin already owns. Rename the skill.";
          plugin = {plugins.probe = src;};
        in
          checkRows "Claude plugin directory ownership" {
            "a distinct plugin key leaves Claude assertions passing" = claudeAssertionsPass (evaluate plugin);
            "a plugin cannot take the reserved personal plugin key" =
              failsWith
              "ai.claude.plugins home-manager would land at ~/.claude/skills/<name>, which the home-manager personal plugin already owns. Rename the plugin key."
              {plugins.home-manager = src;};
            # A single-file skill: a directory skill already collides with the
            # plugin entry itself in the file map.
            "a plugin cannot shadow a single-file skill with the same key" =
              failsWith
              "ai.claude.plugins probe would land at ~/.claude/skills/<name>, which an ai.skills entry already owns. Rename the plugin key."
              (plugin // {skills.probe = skill;});
            "a skill cannot share the directory of a populated personal plugin" =
              failsWith skillConflict
              (personalSkill
                // {
                  mcpServers.remote = {
                    type = "http";
                    url = "https://example.invalid/mcp";
                  };
                });
            "a skill can use the personal plugin key when there is no manifest to deliver" =
              !(failsWith skillConflict personalSkill)
              && (evaluate personalSkill).config.home.file ? ".claude/skills/home-manager/SKILL.md";
          }
      );

      # HM: a top-level normalized ai.agents record fans out to
      # ~/.claude/agents/<name>.md as frontmatter plus body.
      module-claude-hm-top-level-agents-fanout = mkTest "claude-hm-top-level-agents-fanout" (
        let
          result = evalHm {
            ai.claude.enable = true;
            ai.agents.reviewer = {
              description = "Reviews changes.";
              instructions.text = "Review carefully.";
            };
          };
        in
          fromGeneratedTree ".claude/agents/reviewer.md" result.config.home.file.".claude/agents/reviewer.md"
          && (markdownInput result ".claude/agents/reviewer.md").text == "---\ndescription: \"Reviews changes.\"\nname: \"reviewer\"\n---\n\nReview carefully.\n"
      );

      # Precedence: ai.claude.agents wins over ai.agents on name collision.
      module-claude-hm-per-cli-agents-wins = mkTest "claude-hm-per-cli-agents-wins" (
        let
          result = evalHm {
            ai = {
              claude.enable = true;
              agents.reviewer = {
                description = "Top-level.";
                instructions.text = "Top-level.";
              };
              claude.agents.reviewer = "# Claude-specific";
            };
          };
        in
          (markdownInput result ".claude/agents/reviewer.md").text == "# Claude-specific"
      );

      # A handler package enters the document as an absolute executable path;
      # its supporting files ride in the package closure.
      module-claude-hooks-command-package = mkTest "claude-hooks-command-package" (
        let
          pkg = pkgs.runCommand "demo-hook-package" {pname = "demo-hook";} ''
            set -euETo pipefail
            shopt -s inherit_errexit 2>/dev/null || :
            mkdir -p "$out/bin"
            touch "$out/bin/demo-hook" "$out/bin/explicit-hook"
          '';
          explicit = pkg.overrideAttrs {meta.mainProgram = "explicit-hook";};
          commands = package:
            handlerCommands
            (settingsOf backends.hm {
              ai.claude = {
                enable = true;
                hooks.PostToolUse = [{hooks = [{command = package;}];}];
              };
            }).hooks.PostToolUse;
        in
          checkRows "Claude hook package commands" {
            "mainProgram takes precedence over pname" = commands explicit == ["${explicit}/bin/explicit-hook"];
          }
      );

      # ── ai.*.skillsDir Dir helper ──────────────────────────────
      # Directory-of-directories; each immediate subdir becomes a
      # skill. See lib/ai/dir-helpers.nix:skillsFromDir.

      module-claude-skillsdir = mkTest "claude-skillsdir" (
        let
          dir = ./fixtures/claude-skills;
          evaluate = skillsDir:
            evalHm {
              ai.claude = {
                enable = true;
                inherit skillsDir;
              };
            };
          skillPaths = result: builtins.filter (lib.hasPrefix ".claude/skills/") (builtins.attrNames result.config.home.file);
          skillA = ".claude/skills/skill-a/SKILL.md";
          fromRoot = evalHm {
            ai.claude = {
              enable = true;
              skillsDir = dir;
            };
            ai.skills.skill-a = dir + "/skill-b";
          };
        in
          checkRows "Claude skills directory" {
            "directory-generated per-runtime entry beats a same-key root entry" =
              fromRoot.config.home.file.${skillA}.source
              == "${./fixtures/claude-skills/skill-a}/SKILL.md";
            "path form delivers both immediate skill subdirectories" = skillPaths (evaluate dir) == [skillA ".claude/skills/skill-b/SKILL.md"];
            "submodule filter excludes skill-b without dropping skill-a" =
              skillPaths (evaluate {
                path = dir;
                filter = name: name == "skill-a";
              })
              == [skillA];
          }
      );

      # Claude's directory of `.md` agent files expands into raw per-runtime
      # agents. Ensure the backend sees a path source rather than text.
      module-claude-agentsdir = mkTest "claude-agentsdir" (
        let
          dir = ./fixtures/claude-agents;
          evaluate = agentsDir: extra:
            evalHm {
              ai =
                extra
                // {
                  claude = {
                    enable = true;
                    inherit agentsDir;
                  };
                };
            };
          a = ".claude/agents/agent-one.md";
          agentPaths = result: builtins.filter (lib.hasPrefix ".claude/agents/") (builtins.attrNames result.config.home.file);
          fromRoot = evaluate dir {
            agents.agent-one = {
              description = "Explicit top-level agent.";
              instructions.text = "Explicit top-level agent.";
            };
          };
        in
          checkRows "Claude agents directory" {
            "directory-generated per-runtime agent beats a same-key root entry" =
              fromGeneratedTree a fromRoot.config.home.file.${a}
              && (markdownInput fromRoot a).source == ./fixtures/claude-agents/agent-one.md;
            "path form delivers both agents without doubling the suffix" = agentPaths (evaluate dir {}) == [a ".claude/agents/agent-two.md"];
            "submodule filter excludes agent-two without dropping agent-one" =
              agentPaths (evaluate {
                path = dir;
                filter = name: name == "agent-one.md";
              } {})
              == [a];
          }
      );

      # Devenv parity: agents land at project `.claude/agents/<name>.md` through
      # the same renderer as Home Manager's. A semantic root record renders
      # frontmatter + body; a per-runtime null tombstone suppresses a root entry;
      # nothing warns about an undelivered surface.
      module-claude-devenv-agents = mkTest "claude-devenv-agents" (
        let
          result = evalDevenv {
            ai = {
              agents = {
                probe = {
                  description = "Probe agent.";
                  instructions.text = "PROBE-AGENT-BODY-TOKEN.";
                };
                suppressed = {
                  description = "Suppressed agent.";
                  instructions.text = "Suppressed agent.";
                };
              };
              claude = {
                enable = true;
                agents = {
                  # A store-path STRING, as a flake input yields: a source,
                  # the way Home Manager's `isPathLike` classifies it.
                  store-string = "${./fixtures/claude-agents}/agent-one.md";
                  suppressed = null;
                };
              };
            };
          };
          inherit (markdownInput result ".claude/agents/probe.md") text;
          storeString = markdownInput result ".claude/agents/store-string.md";
        in
          toString (storeString.source or "")
          == "${./fixtures/claude-agents}/agent-one.md"
          && fromGeneratedTree ".claude/agents/store-string.md" result.config.files.".claude/agents/store-string.md"
          && fromGeneratedTree ".claude/agents/probe.md" result.config.files.".claude/agents/probe.md"
          && lib.hasInfix "name: \"probe\"" text
          && lib.hasInfix "description: \"Probe agent.\"" text
          && lib.hasInfix "PROBE-AGENT-BODY-TOKEN." text
          && !(result.config.files ? ".claude/agents/suppressed.md")
          && !(lib.any (lib.hasInfix "agents") result.config.warnings)
      );

      # Devenv parity for `agentsDir`: each `.md` becomes a path-valued agent
      # delivered as its own file, with no undelivered-surface warning.
      module-claude-devenv-agentsdir = mkTest "claude-devenv-agentsdir" (
        let
          result = evalDevenv {
            ai.claude = {
              enable = true;
              agentsDir = {
                path = ./fixtures/claude-agents;
                filter = name: name == "agent-one.md";
              };
            };
          };
          file = markdownInput result ".claude/agents/agent-one.md";
          # The same directory as a store-path string, as a flake input yields.
          fromString = evalDevenv {
            ai.claude = {
              enable = true;
              agentsDir = {
                path = "${./fixtures/claude-agents}";
                filter = name: name == "agent-one.md";
              };
            };
          };
          stringFile = markdownInput fromString ".claude/agents/agent-one.md";
        in
          (file.source or null)
          == ./fixtures/claude-agents/agent-one.md
          && fromGeneratedTree ".claude/agents/agent-one.md" result.config.files.".claude/agents/agent-one.md"
          && toString (stringFile.source or "") == "${./fixtures/claude-agents}/agent-one.md"
          && !(result.config.files ? ".claude/agents/agent-two.md")
          && !(lib.any (lib.hasInfix "agentsDir") result.config.warnings)
      );

      # ── ai.claude.hookScriptsDir Dir helper ────────────────────
      # Claude-only per plan §5 (hook scripts are a Claude-specific
      # concept). See lib/ai/dir-helpers.nix:hooksFromDir. Default
      # filter is always-true — hook files are typically
      # extensionless shell scripts, so no `.md`-like suffix strip.

      module-claude-hookscriptsdir = mkTest "claude-hookscriptsdir" (
        let
          dir = ./fixtures/claude-hooks;
          config = extra: {
            ai.claude =
              {
                enable = true;
                hookScriptsDir = dir;
              }
              // extra;
          };
          unfiltered = config {};
          filtered = evalHm (config {
            hookScriptsDir = {
              path = dir;
              filter = name: name == "pre-edit";
            };
          });
          overridden = evalHm (config {hookScripts.pre-edit = "explicit override";});
          hookPaths = files: builtins.filter (lib.hasPrefix ".claude/hooks/") (builtins.attrNames files);
          expected = [".claude/hooks/post-edit" ".claude/hooks/pre-edit"];
        in
          checkRows "Claude hooks directory" {
            "devenv delivers both extensionless hook scripts" = hookPaths (evalDevenv unfiltered).config.files == expected;
            # Hook scripts have no shared pool: within this layer the directory
            # expansion gives its attrsOf lines defaults lower priority.
            "inline script replaces the directory script rather than concatenating it" = deliveredMarkdown overridden ".claude/hooks/pre-edit" == "explicit override";
            "submodule filter excludes post-edit without dropping pre-edit" = hookPaths filtered.config.home.file == [".claude/hooks/pre-edit"];
          }
      );

      module-claude-hm-rule-sourcepath-rejected = mkTest "claude-hm-rule-sourcepath-rejected" (
        checkRows "per-runtime Claude rule options" {
          "a text rule rejects the undeclared sourcePath field" = rejectsChange (rule:
            (evalHm {
              ai.claude = {
                enable = true;
                rules.my-rule = rule;
              };
            }).config.ai.claude.rules.my-rule.text) {
            valid.text = "body";
            invalid = {
              sourcePath = "/abs/path/to/my-rule.md";
              text = "body";
            };
            expected = "body";
          };
        }
      );
    }
    // families.checks;
}
