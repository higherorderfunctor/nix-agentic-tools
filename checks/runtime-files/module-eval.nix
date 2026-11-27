# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode sembleignore
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) checkRows deliveredFiles deliveredMarkdown deliveredTree evalDevenv evalHm fromGeneratedTree harnessNames mkTest rejectsChange setEnable;
  inherit (import ../../packages/ai-module/lib/files/default.nix {inherit lib pkgs;}) validate;
  fixtureSource = ../../packages/kiro-cli/checks/fixtures/kiro-steering/alpha.md;
  claudeFile = target: entry: {
    ai.claude = {
      enable = true;
      files.${target} = entry;
    };
  };
  # Inspect the exact refusal on the forwarded record, then force the real HM
  # sink: the diagnostic alone would pass if lowering stopped enforcing it.
  hmIssue = config:
    validate {
      backend = "hm";
      files = config.ai.files;
      namespace = "ai";
    };
  # Build-time probes must not realize input that a final file discards.
  unbuildable = name:
    pkgs.runCommand name {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      exit 1
    '';
  # A delivered Markdown file's text, from the evaluated `config`.
  markdownOf = config: path:
    if fromGeneratedTree path (deliveredFiles config).${path}
    then deliveredMarkdown {inherit config;} path
    else config.ai.files.${path}.content.text;
in {
  checks = {
    # ── A5a: final per-runtime literal file registry ────────────────────
    module-runtime-files-option-parity = mkTest "runtime-files-option-parity" (
      let
        hm = evalHm {};
        devenv = evalDevenv {};
        optionType = evaluated: runtime:
          (lib.getAttrFromPath ["ai" runtime "files"] evaluated.options).type.description;
      in
        lib.all (runtime: optionType hm runtime == optionType devenv runtime) harnessNames
    );

    module-runtime-files-lower-to-both-backends = let
      runtimeCheck = runtime: backend: evaluate: let
        textTarget = "literal/${runtime}.txt";
        sourceTarget = "literal/${runtime}.source";
        text = "${runtime}-TEXT";
        config = lib.recursiveUpdate (setEnable runtime true) {
          ai.${runtime}.files = {
            ${sourceTarget}.content.source = fixtureSource;
            ${textTarget} = {
              content = {inherit text;};
              executable = true;
            };
          };
        };
        evaluated = evaluate config;
        files = deliveredFiles evaluated.config;
      in
        assert lib.assertMsg (
          evaluated.config.ai.files.${textTarget}.content.text
          == text
          && evaluated.config.ai.files.${sourceTarget}.content.source == fixtureSource
          && files.${textTarget}.executable
          && toString files.${sourceTarget}.source == toString fixtureSource
          && !(files.${sourceTarget} ? text)
        ) "${runtime}/${backend}: literal files must preserve text, source and executable metadata"; ''
          printf '%s\n' ${lib.escapeShellArg "Checking ${runtime}/${backend} literal text"} >&2
          ${pkgs.diffutils}/bin/cmp <(printf '%s' ${lib.escapeShellArg text}) ${lib.escapeShellArg (toString files.${textTarget}.source)}
        '';
      checks = lib.concatMapStrings (runtime: runtimeCheck runtime "devenv" evalDevenv + runtimeCheck runtime "hm" evalHm) harnessNames;
    in
      pkgs.runCommand "module-test-runtime-files-lower-to-both-backends" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        ${checks}
        echo PASS > "$out"
      '';

    # A disabled runtime emits nothing it declares, and an enabled runtime's
    # entry switched off with `enable = false` needs no content.
    module-runtime-files-disabled-runtime-does-not-emit = mkTest "runtime-files-disabled-runtime-does-not-emit" (
      let
        target = "literal/disabled.txt";
        config.ai.claude.files.${target}.content.text = "DECLARED-BUT-DISABLED";
        hm = (evalHm config).config;
        devenv = (evalDevenv config).config;
        switchedOff = evaluate:
          (evaluate {
            ai.claude = {
              enable = true;
              files."literal/disabled".enable = false;
            };
          }).config;
      in
        hm.ai.claude.files.${target}.content.text
        == "DECLARED-BUT-DISABLED"
        && !(hm.ai.files ? ${target})
        && !(hm.home.file ? ${target})
        && !(devenv.files ? ${target})
        && !((switchedOff evalHm).home.file ? "literal/disabled")
        && !((deliveredFiles (switchedOff evalDevenv)) ? "literal/disabled")
    );

    module-runtime-files-invalid-targets-rejected = mkTest "runtime-files-invalid-targets-rejected" (
      let
        target = "literal/probe";
        text = {content.text = "probe";};
        evaluate = path: (evalHm (claudeFile path text)).config;
        valid = evaluate target;
        rejectsTarget = path: let
          invalid = evaluate path;
        in
          hmIssue invalid
          == ''files."${path}": target must be a normalized relative path without empty, . or .. segments''
          && rejectsChange (config: config.home.file ? ${target}) {
            inherit valid invalid;
            expected = true;
          };
      in
        checkRows "runtime file targets" {
          "absolute target" = rejectsTarget "/absolute";
          "dot segment" = rejectsTarget "./dot";
          "empty segment" = rejectsTarget "double//slash";
          "empty target" = rejectsTarget "";
          "parent segment" = rejectsTarget "parent/../escape";
        }
    );

    module-runtime-files-content-shape-rejected = mkTest "runtime-files-content-shape-rejected" (
      let
        target = "literal/probe";
        evaluate = entry: (evalHm (claudeFile target entry)).config;
        delivered = config: config.home.file ? ${target};
        disabled = evaluate {enable = false;};
        applyCommand = config: config.home.activation.ai-files-apply.text or "";
        # Force the native link map without walking its derivations. The apply
        # command must differ from the disabled control even without a native link.
        reachesSink = config:
          builtins.seq (delivered config) (let
            command = applyCommand config;
          in
            lib.hasInfix "--phase apply" command && command != applyCommand disabled);
        textEntry = {content.text = "probe";};
        runEntry = {
          content.run = "printf '{}'";
          method = "ro";
        };
        # Equal-priority alternatives are rejected by the shared content
        # selection, not by a method/format constraint on one of the forms.
        rejectsTie = alternatives: valid: content: let
          invalid = evaluate (lib.recursiveUpdate valid {inherit content;});
        in
          hmIssue invalid
          == ''files."${target}": content alternatives tie at priority 100: ${alternatives}''
          && rejectsChange reachesSink {
            inherit invalid;
            valid = evaluate valid;
            expected = true;
          };
      in
        checkRows "runtime file content restrictions" {
          # An explicit enable flag is the disabled shape, not a null sentinel.
          "disabled entry needs no content" = !disabled.ai.claude.files.${target}.enable && !delivered disabled;
          "equal-priority run and text" = rejectsTie "run, text" runEntry textEntry.content;
          "equal-priority run and value" = rejectsTie "run, value" (runEntry // {format = "json";}) {value.probe = true;};
          "equal-priority source and text" = rejectsTie "source, text" textEntry {source = fixtureSource;};
          # An entry with `text` at the top level has not been migrated;
          # accepting it would deliver a file with no bytes.
          "retired flat text field is not a runtime file option" = rejectsChange (config: config.ai.claude.files.${target}.content.text) {
            valid = evaluate textEntry;
            invalid = evaluate {text = "probe";};
            expected = "probe";
          };
        }
    );

    module-runtime-files-generated-default-disable = mkTest "runtime-files-generated-default-disable" (
      let
        target = ".claude/CLAUDE.md";
        config.ai.claude = {
          enable = true;
          context.text = "GENERATED-CONTEXT";
          files.${target}.enable = false;
        };
        hm = (evalHm config).config;
        devenv = (evalDevenv config).config;
      in
        !hm.ai.files.${target}.enable
        && !devenv.ai.files.${target}.enable
        && !(hm.home.file ? ${target})
        && !(devenv.files ? ${target})
    );

    # Positive inclusion inventory: every primary normalized output reaches its
    # runtime map, or the one shared repository AGENTS.md map, before lowering.
    module-runtime-files-primary-inclusion-contract = mkTest "runtime-files-primary-inclusion-contract" (
      let
        config = {
          ai = {
            context.text = "SHARED-CONTEXT";
            rules.scoped = {
              matcher = ["src/**"];
              text = "SCOPED-RULE";
            };
            claude.enable = true;
            codex.enable = true;
            copilot.enable = true;
            kimchi.enable = true;
            kiro.cli.enable = true;
          };
        };
        hm = evalHm config;
        devenv = evalDevenv config;
        hmConfig = hm.config;
        devenvConfig = devenv.config;
      in
        hmConfig.ai.claude._generatedFiles ? ".claude/CLAUDE.md"
        && hmConfig.ai.claude._generatedFiles ? ".claude/rules/scoped.md"
        && hmConfig.ai.codex._generatedFiles ? ".codex/AGENTS.md"
        && hmConfig.ai.kimchi._generatedFiles ? ".config/kimchi/harness/AGENTS.md"
        && hmConfig.ai.kiro._generatedFiles ? ".kiro/steering/AGENTS.md"
        && hmConfig.ai.kiro._generatedFiles ? ".kiro/steering/scoped.md"
        && devenvConfig.ai.claude._generatedFiles ? ".claude/CLAUDE.md"
        && devenvConfig.ai.claude._generatedFiles ? ".claude/rules/scoped.md"
        && devenvConfig.ai.copilot._generatedFiles ? ".github/copilot-instructions.md"
        && !(devenvConfig.ai.internal.agentsMdTargets ? copilot)
        && devenvConfig.ai.copilot._generatedFiles ? ".github/instructions/scoped.instructions.md"
        && devenvConfig.ai.internal.agentsMd ? "AGENTS.md"
        && devenvConfig.ai.kiro._generatedFiles ? ".kiro/steering/scoped.md"
        && devenvConfig.ai.internal._generatedFiles ? "AGENTS.md"
        && deliveredTree devenv "AGENTS.md" == devenvConfig.ai.internal._generatedTree
        && lib.hasInfix "SHARED-CONTEXT" (markdownOf devenvConfig "AGENTS.md")
    );

    module-runtime-files-shared-agentsmd-arbitration = mkTest "runtime-files-shared-agentsmd-arbitration" (
      let
        base = {
          ai = {
            codex.enable = true;
            context.text = "GENERATED-SHARED-CONTEXT";
            kimchi.enable = true;
            kiro.cli.enable = true;
          };
        };
        replaced = evalDevenv (lib.recursiveUpdate base {
          ai.codex.files."AGENTS.md".content.text = "CONSUMER-REPLACEMENT";
        });
        suppressed = evalDevenv (lib.recursiveUpdate base {
          ai.kiro.files."AGENTS.md".enable = false;
        });
        sharedText = kimchiText:
          lib.recursiveUpdate base {
            ai = {
              codex.files."AGENTS.md".content.text = "SHARED-CONSUMER";
              kimchi.files."AGENTS.md".content.text = kimchiText;
              kiro.files."AGENTS.md".content.text = "SHARED-CONSUMER";
            };
          };
        deduplicated = evalDevenv (sharedText "SHARED-CONSUMER");
        divergent = rejectsChange (config: (evalDevenv config).config.ai.files."AGENTS.md".content.text) {
          valid = sharedText "SHARED-CONSUMER";
          invalid = sharedText "KIMCHI-CONSUMER";
          expected = "SHARED-CONSUMER";
        };
        # The consumerOnly* cases have NO generated context, so Kimchi never
        # registers its generated shared target. A consumer-authored final
        # AGENTS.md must still arbitrate with Codex's, land alone, suppress,
        # and reject a text-versus-suppression conflict. Ported from #1849.
        consumerOnly = kimchiEntry:
          evalDevenv {
            ai = {
              codex = {
                enable = true;
                files."AGENTS.md" = {
                  enable = true;
                  content.text = "CONSUMER-ONLY";
                };
              };
              kimchi = {
                enable = true;
                files."AGENTS.md" = kimchiEntry;
              };
            };
          };
        consumerAgreement = (consumerOnly {content.text = "CONSUMER-ONLY";}).config;
        kimchiConsumerOnly = evalDevenv {
          ai.kimchi = {
            enable = true;
            context.filename = "custom.md";
            files."AGENTS.md".content.text = "KIMCHI-CONSUMER-ONLY";
          };
        };
        # Generated Kimchi context beside a custom (Home Manager) filename. The
        # devenv factory still writes AGENTS.md, so a public override on that
        # path must arbitrate with the shared owner rather than fail its
        # aggregate assertion for a context.filename that names another file.
        kimchiContextOverride = evalDevenv {
          ai.kimchi = {
            enable = true;
            context = {
              filename = "custom.md";
              text = "KIMCHI-GENERATED";
            };
            files."AGENTS.md".content.text = "KIMCHI-CONTEXT-OVERRIDE";
          };
        };
        consumerOnlySuppressed = evalDevenv {
          ai.kimchi = {
            enable = true;
            context.filename = "custom.md";
            files."AGENTS.md".enable = false;
          };
        };
        # Identical to consumerOnly except Kimchi suppresses instead of
        # agreeing. The rejection is pinned to its cause: the merged `enable`
        # throws, and the definitions reaching it are exactly one suppression
        # and one enabled text, so an unrelated evaluation failure cannot pass
        # for this one.
        consumerSuppressionConflict = (consumerOnly {enable = false;}).config;
        rejectsSuppression = read: expected:
          rejectsChange read {
            valid = consumerAgreement;
            invalid = consumerSuppressionConflict;
            inherit expected;
          };
        # A source-backed consumer AGENTS.md beside generated context. Only the
        # shared owner may lower it: when a runtime's ordinary sink lowers the
        # same target too (the runtime missing from mkBackendTransform's
        # sharedAgentsMdTargets), the second `source` definition conflicts and
        # this throws. Identical text from two sinks merges silently, which is
        # why the text cases above could not catch that bypass.
        sourced = runtime: let
          file = pkgs.writeText "${runtime}-agents.md" "SOURCED-${runtime}";
          evaluated = evalDevenv (lib.recursiveUpdate base {
            ai.${runtime}.files."AGENTS.md".content.source = file;
          });
        in
          (deliveredFiles evaluated.config)."AGENTS.md".source == toString file;
      in
        checkRows "shared AGENTS.md arbitration" {
          "agreeing consumers without generated context" = markdownOf consumerAgreement "AGENTS.md" == "CONSUMER-ONLY";
          "agreeing overrides deduplicate" = markdownOf deduplicated.config "AGENTS.md" == "SHARED-CONSUMER";
          "consumer replaces generated context" =
            replaced.config.ai.files."AGENTS.md".content.text
            == "CONSUMER-REPLACEMENT"
            && markdownOf replaced.config "AGENTS.md" == "CONSUMER-REPLACEMENT";
          "consumer suppresses generated context" =
            !suppressed.config.ai.files."AGENTS.md".enable
            && !((deliveredFiles suppressed.config) ? "AGENTS.md");
          "different consumer text conflicts at the merged leaf" = divergent;
          "explicit enable and suppression conflict at the merged leaf and sink" =
            rejectsSuppression (config: config.ai.files."AGENTS.md".enable) true
            && rejectsSuppression (config: (deliveredFiles config) ? "AGENTS.md") true;
          "Kimchi consumer suppression does not emit either name" =
            !((deliveredFiles consumerOnlySuppressed.config) ? "AGENTS.md")
            && !((deliveredFiles consumerOnlySuppressed.config) ? "custom.md");
          "Kimchi generated context can be overridden despite a custom HM filename" =
            markdownOf kimchiContextOverride.config "AGENTS.md"
            == "KIMCHI-CONTEXT-OVERRIDE"
            && lib.all (assertion: assertion.assertion) kimchiContextOverride.config.assertions;
          "Kimchi standalone consumer text is delivered at the shared path" =
            markdownOf kimchiConsumerOnly.config "AGENTS.md"
            == "KIMCHI-CONSUMER-ONLY"
            && !((deliveredFiles kimchiConsumerOnly.config) ? "custom.md");
          "source-backed Codex entry has one lowering owner" = sourced "codex";
          "source-backed Kimchi entry has one lowering owner" = sourced "kimchi";
          "source-backed Kiro entry has one lowering owner" = sourced "kiro";
        }
    );

    module-runtime-files-shared-agentsmd-ignores-disabled-runtime = mkTest "runtime-files-shared-agentsmd-ignores-disabled-runtime" (
      let
        withDormantEntry = {
          activeRuntime,
          dormantRuntime,
          entry,
        }:
          evalDevenv (lib.recursiveUpdate (setEnable activeRuntime true) {
            ai = {
              context.text = "ACTIVE-SHARED-CONTEXT";
              ${dormantRuntime}.files."AGENTS.md" = entry;
            };
          });
        evaluations = [
          (withDormantEntry {
            activeRuntime = "codex";
            dormantRuntime = "kimchi";
            entry.content.text = "DORMANT-KIMCHI";
          })
          (withDormantEntry {
            activeRuntime = "kimchi";
            dormantRuntime = "codex";
            entry = null;
          })
          (withDormantEntry {
            activeRuntime = "codex";
            dormantRuntime = "kiro";
            entry.content.text = "DORMANT-KIRO";
          })
          (withDormantEntry {
            activeRuntime = "codex";
            dormantRuntime = "kiro";
            entry = null;
          })
          (withDormantEntry {
            activeRuntime = "kiro";
            dormantRuntime = "codex";
            entry.content.text = "DORMANT-CODEX";
          })
          (withDormantEntry {
            activeRuntime = "kiro";
            dormantRuntime = "codex";
            entry = null;
          })
        ];
      in
        lib.all (evaluated:
          (deliveredFiles evaluated.config) ? "AGENTS.md"
          && lib.hasInfix "ACTIVE-SHARED-CONTEXT" (markdownOf evaluated.config "AGENTS.md")
          && !(lib.hasInfix "DORMANT-" (markdownOf evaluated.config "AGENTS.md")))
        evaluations
    );

    # Layer-1 replacements discard oversized generated content unread, and
    # suppression removes delivery. Generated defaults retain their byte limit;
    # consumer content bypasses that generated-tree guard.
    module-runtime-files-byte-limit-follows-final-entry = let
      oversized = lib.concatStrings (lib.replicate 64 "x");
      override = evaluate: target: contextPath: entry:
        evaluate {
          ai = lib.recursiveUpdate (lib.setAttrByPath contextPath oversized) {
            codex = {
              enable = true;
              files.${target} = entry;
              projectDocMaxBytes = 8;
            };
          };
        };
      overrideHm = override evalHm ".codex/AGENTS.md" ["codex" "context" "text"];
      overrideDevenv = override evalDevenv "AGENTS.md" ["context" "text"];
      replacement.content.text = "short";
      hmReplacement = overrideHm replacement;
      hmDisabled = overrideHm {enable = false;};
      devenvReplacement = overrideDevenv replacement;
      devenvDisabled = overrideDevenv {enable = false;};
      passes = evaluated: builtins.all (assertion: assertion.assertion) evaluated.config.assertions;
      hmFile = hmReplacement.config.home.file.".codex/AGENTS.md";
      devenvFile = (deliveredFiles devenvReplacement.config)."AGENTS.md";
    in
      assert lib.assertMsg (lib.all passes [hmReplacement hmDisabled devenvReplacement devenvDisabled])
      "runtime-files-byte-limit-follows-final-entry: a fixture fails its assertions";
      assert lib.assertMsg (markdownOf hmReplacement.config ".codex/AGENTS.md" == "short" && markdownOf devenvReplacement.config "AGENTS.md" == "short")
      "runtime-files-byte-limit-follows-final-entry: the replacement does not reach the final entry";
      assert lib.assertMsg (hmReplacement.config.ai.codex._maxBytes.".codex/AGENTS.md".bytes == 8 && devenvReplacement.config.ai.internal.agentsMd."AGENTS.md".maxBytes == 8)
      "runtime-files-byte-limit-follows-final-entry: the replacement's path lost its limit";
      assert devenvFile.text == "short";
      assert lib.assertMsg (!(hmDisabled.config.home.file ? ".codex/AGENTS.md") && !((deliveredFiles devenvDisabled.config) ? "AGENTS.md"))
      "runtime-files-byte-limit-follows-final-entry: a disabled AGENTS.md is still delivered";
        pkgs.runCommand "module-test-runtime-files-byte-limit-follows-final-entry" {} ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          [ "$(cat ${hmFile.source})" = short ]
          echo PASS > "$out"
        '';

    module-runtime-files-discarded-codex-source-stays-lazy = mkTest "runtime-files-discarded-codex-source-stays-lazy" (
      let
        source = unbuildable "discarded-codex-context-must-not-build";
        fixture = evaluate: runtime: target: entry:
          (evaluate (lib.recursiveUpdate (setEnable runtime true) {
            ai = {
              context = {inherit source;};
              ${runtime} = {
                context.text = "RUNTIME-CONTEXT";
                files.${target} = entry;
              };
            };
          })).config;
        replaced = evaluate: target: text:
          markdownOf (fixture evaluate "codex" target {content = {inherit text;};}) target == text;
        disabled = evaluate: runtime: target:
          !(deliveredFiles (fixture evaluate runtime target {enable = false;}) ? ${target});
      in
        checkRows "final file must not read discarded context source" {
          "devenv Codex replacement" = replaced evalDevenv "AGENTS.md" "DEVENV-REPLACEMENT";
          "devenv Codex suppression" = disabled evalDevenv "codex" "AGENTS.md";
          "devenv Kiro suppression" = disabled evalDevenv "kiro" "AGENTS.md";
          "home-manager Codex replacement" = replaced evalHm ".codex/AGENTS.md" "HM-REPLACEMENT";
          "home-manager Codex suppression" = disabled evalHm "codex" ".codex/AGENTS.md";
          "home-manager Kiro suppression" = disabled evalHm "kiro" ".kiro/steering/AGENTS.md";
        }
    );

    module-runtime-files-generated-empty-codex-source-omitted = mkTest "runtime-files-generated-empty-codex-source-omitted" (
      let
        source = ../../lib/testing/fixtures/empty;
        hmCodex = evalHm {
          ai = {
            context = {inherit source;};
            codex.enable = true;
          };
        };
        devenvCodex = evalDevenv {
          ai = {
            context = {inherit source;};
            codex.enable = true;
          };
        };
        devenvKiro = evalDevenv {
          ai = {
            context = {inherit source;};
            kiro.cli.enable = true;
          };
        };
      in
        !(hmCodex.config.home.file ? ".codex/AGENTS.md")
        && !((deliveredFiles devenvCodex.config) ? "AGENTS.md")
        && !((deliveredFiles devenvKiro.config) ? "AGENTS.md")
    );

    # Content at `mkDefault` is still content: the leaf-default idiom a
    # downstream module uses for an overridable file must deliver it, not
    # leave a record that nothing writes and nothing reports. A layer-1 entry
    # lands as its own bytes, outside the generated tree.
    module-runtime-files-default-priority-content-delivers = mkTest "runtime-files-default-priority-content-delivers" (
      let
        source = fixtureSource;
        config.ai.claude = {
          enable = true;
          files = {
            "literal/default-source.md".content.source = lib.mkDefault source;
            "literal/default-text.md".content.text = lib.mkDefault "DEFAULT-TEXT";
          };
        };
        delivered = evaluated:
          (deliveredFiles evaluated.config)."literal/default-source.md".source
          == source
          && deliveredFiles evaluated.config ? "literal/default-text.md"
          && evaluated.config.ai.files."literal/default-text.md".content.text == "DEFAULT-TEXT";
      in
        delivered (evalHm config)
        && delivered (evalDevenv config)
    );

    # Entry enable suppresses structured values and run content.
    module-runtime-files-disable-suppresses-every-form = mkTest "runtime-files-disable-suppresses-every-form" (
      lib.all (evaluate:
        lib.all (content:
          lib.all (enable: let
            inherit
              ((evaluate {
                ai.kiro = {
                  cli.enable = true;
                  files.".kiro/probe.json" = {
                    inherit content;
                    enable = lib.mkForce enable;
                    format = "json";
                    method =
                      if content ? run
                      then "ro"
                      else "symlink";
                  };
                };
              }))
              config
              ;
            entry = config.ai.files.".kiro/probe.json";
            delivered = deliveredFiles config;
          in
            entry.enable == enable && (delivered ? ".kiro/probe.json") == enable)
          [false true]) [{value.a = true;} {value.a = lib.mkDefault true;} {run = "printf '{}'";}]) [evalHm evalDevenv]
    );

    # A store-backed replacement of the shared AGENTS.md stays lazy: its size
    # limit is measured when its generated tree is built, never by reading it
    # during evaluation. The source is a derivation that fails to build.
    module-runtime-files-shared-agentsmd-source-stays-lazy = mkTest "runtime-files-shared-agentsmd-source-stays-lazy" (
      let
        source = unbuildable "shared-agents-md-source-must-not-build";
        evaluated = evalDevenv {
          ai = {
            codex = {
              enable = true;
              files."AGENTS.md".content.source = source;
              projectDocMaxBytes = 8;
            };
            context.text = "SHARED-CONTEXT";
          };
        };
      in
        builtins.all (assertion: assertion.assertion) evaluated.config.assertions
        && (deliveredFiles evaluated.config)."AGENTS.md".source == toString source
    );

    module-runtime-files-discarded-composed-context-stays-lazy = mkTest "runtime-files-discarded-composed-context-stays-lazy" (
      let
        source = unbuildable "discarded-runtime-contexts-must-not-build";
        hmClaude = evalHm {
          ai = {
            context = {inherit source;};
            claude = {
              context.text = "RUNTIME-CONTEXT";
              enable = true;
              files.".claude/CLAUDE.md".content.text = "CLAUDE-REPLACEMENT";
            };
          };
        };
        devenvClaude = evalDevenv {
          ai = {
            context = {inherit source;};
            claude = {
              context.text = "RUNTIME-CONTEXT";
              enable = true;
              files.".claude/CLAUDE.md".content.text = "CLAUDE-REPLACEMENT";
            };
          };
        };
        # A layer-1 replacement lands as its own bytes, outside the tree, and
        # instantiating it instantiates the tree it requires.
        claudeText = evaluated:
          builtins.seq (toString (deliveredFiles evaluated.config).".claude/CLAUDE.md".source)
          evaluated.config.ai.files.".claude/CLAUDE.md".content.text;
        # Switched off at layer 1, the context stays out of the tree too.
        claudeOff = evaluate: let
          evaluated = evaluate {
            ai = {
              context = {inherit source;};
              claude = {
                context.text = "RUNTIME-CONTEXT";
                enable = true;
                files.".claude/CLAUDE.md".enable = false;
                rules.probe.text = "probe";
              };
            };
          };
        in
          !(deliveredFiles evaluated.config ? ".claude/CLAUDE.md")
          && builtins.isString evaluated.config.ai.claude._generatedTree.drvPath;
        hmKimchi = evalHm {
          ai = {
            context = {inherit source;};
            kimchi = {
              context.text = "RUNTIME-CONTEXT";
              enable = true;
              files.".config/kimchi/harness/AGENTS.md".content.text = "KIMCHI-REPLACEMENT";
            };
          };
        };
        devenvKimchi = evalDevenv {
          ai = {
            context = {inherit source;};
            kimchi = {
              context.text = "RUNTIME-CONTEXT";
              enable = true;
              files."AGENTS.md".content.text = "KIMCHI-REPLACEMENT";
            };
          };
        };
      in
        claudeText hmClaude
        == "CLAUDE-REPLACEMENT"
        && claudeText devenvClaude == "CLAUDE-REPLACEMENT"
        && lib.all claudeOff [evalHm evalDevenv]
        && builtins.isString (toString (deliveredFiles hmKimchi.config).".config/kimchi/harness/AGENTS.md".source)
        && hmKimchi.config.ai.files.".config/kimchi/harness/AGENTS.md".content.text == "KIMCHI-REPLACEMENT"
        && hmKimchi.config.ai.files.".config/kimchi/harness/AGENTS.md".method == "symlink"
        && devenvKimchi.config.ai.files."AGENTS.md".method == "ro"
        && (deliveredFiles devenvKimchi.config)."AGENTS.md".text == "KIMCHI-REPLACEMENT"
    );

    module-ai-checks-routes-files-by-surface = let
      evaluated = evalDevenv {
        ai = {
          checks.context = "# comment-only check";
          checks.rules = ''
            test "$AI_RUNTIME" = claude
            test "$#" = 1
            test "$1" = .claude/rules/probe.md
            test -f "$1"
            touch .rules-check-ran
          '';
          claude = {
            enable = true;
            skills.probe = ../../packages/ai-module/checks/fixtures/probe-skill;
          };
          context.text = "probe";
          rules.probe.text = "probe";
        };
      };
      tree = deliveredTree evaluated ".claude/rules/probe.md";
      internal = evalDevenv {
        ai = {
          checks.context = ''
            test "$AI_RUNTIME" = internal
            test "$#" = 1
            test "$1" = AGENTS.md
            test -f "$1"
            touch .context-check-ran
          '';
          codex.enable = true;
          context.text = "probe";
        };
      };
      internalTree = deliveredTree internal "AGENTS.md";
    in
      pkgs.runCommand "module-test-ai-checks-routes-files-by-surface" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        require_marker() {
          if ! test -e "$1"; then
            printf 'Generated-file check did not create %s\n' "$1" >&2
            return 1
          fi
        }
        require_marker ${tree}/.rules-check-ran
        require_marker ${internalTree}/.context-check-ran
        touch "$out"
      '';

    module-ai-checks-failure-names-surface-and-runtime = let
      evaluated = evalDevenv {
        ai = {
          checks.skills = "exit 7";
          claude = {
            enable = true;
            skills.probe = ../../packages/ai-module/checks/fixtures/probe-skill;
          };
        };
      };
      expectedFailure = pkgs.testers.testBuildFailure evaluated.config.ai.claude._generatedTree;
    in
      pkgs.runCommand "module-test-ai-checks-failure-names-surface-and-runtime" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        grep -q -F 'Generated-file check failed for surface skills in runtime claude (exit 7)' ${expectedFailure}/testBuildFailure.log
        touch "$out"
      '';

    module-ai-checks-tier-replacement = let
      fixture = {
        ai = {
          checks = {
            all = "exit 1";
            # Nix-installed Claude always has settings, independent of rules.
            settings = ''
              test "$AI_RUNTIME" = claude
              test "$#" = 1
              test "$1" = .claude/settings.json
              ${pkgs.jq}/bin/jq -e '. == {
                "$schema": "https://json.schemastore.org/claude-code-settings.json",
                "env": {"DISABLE_AUTOUPDATER": "1"}
              }' "$1" >/dev/null
              touch .settings-check-ran
            '';
          };
          claude.enable = true;
          gitSshConfigWorkaround = false;
          rules.probe.text = "probe";
        };
      };
      replaced =
        (evalDevenv (lib.recursiveUpdate fixture {
          ai.claude.checks.rules = "";
        })).config;
      inherited = (evalDevenv fixture).config;
      expectedFailure = pkgs.testers.testBuildFailure inherited.ai.claude._generatedTree;
    in
      assert replaced.ai.claude.checks.rules == "";
      assert inherited.ai.claude.checks.rules == "exit 1";
        pkgs.runCommand "module-test-ai-checks-tier-replacement" {} ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          test -e ${replaced.ai.claude._generatedTree}/.claude/rules/probe.md
          test -e ${replaced.ai.claude._generatedTree}/.settings-check-ran
          grep -q -F 'Generated-file check failed for surface rules in runtime claude (exit 1)' ${expectedFailure}/testBuildFailure.log
          touch "$out"
        '';

    module-ai-checks-stamp-coverage = mkTest "ai-checks-stamp-coverage" (
      let
        specimen = import ./specimen.nix {inherit lib;};
        # Pin a required stamp for each runtime and backend with generated
        # files, so an empty inventory cannot pass. Copilot has no HM tree.
        required = {
          devenv = {
            claude.".claude/CLAUDE.md" = "context";
            codex.".codex/config.toml" = "settings";
            copilot.".github/copilot-instructions.md" = "context";
            kimchi.".kimchi/mcp.json" = "mcpServers";
            kiro.".kiro/steering/scoped.md" = "rules";
          };
          hm = {
            claude.".claude/CLAUDE.md" = "context";
            codex.".codex/AGENTS.md" = "context";
            copilot = {};
            kimchi.".config/kimchi/harness/AGENTS.md" = "context";
            kiro.".kiro/steering/AGENTS.md" = "context";
          };
        };
        rows = mode: evaluate: runtime: let
          entries = (evaluate (specimen mode runtime)).config.ai.${runtime}._generatedFiles;
        in
          lib.mapAttrs' (path: entry: lib.nameValuePair "${runtime}/${mode}/${path} has no surface stamp" (entry.surface != null)) entries
          // lib.mapAttrs' (path: surface:
            lib.nameValuePair "${runtime}/${mode}/${path} must be stamped ${surface}" (
              (entries.${path}.surface or null) == surface
            ))
          required.${mode}.${runtime};
        runtimeRows = lib.concatMap (runtime: [(rows "devenv" evalDevenv runtime) (rows "hm" evalHm runtime)]) harnessNames;
      in
        checkRows "generated-file surface stamps" (lib.mergeAttrsList runtimeRows)
    );
  };
}
