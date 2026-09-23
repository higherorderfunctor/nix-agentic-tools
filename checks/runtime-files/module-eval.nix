# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode sembleignore
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) evalDevenv evalHm harnessNames mkTest;
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

    module-runtime-files-lower-to-both-backends = mkTest "runtime-files-lower-to-both-backends" (
      let
        checkRuntime = runtime: let
          textTarget = "literal/${runtime}.txt";
          sourceTarget = "literal/${runtime}.source";
          config = {
            ai.${runtime} = {
              enable = true;
              files = {
                ${textTarget} = {
                  content.text = "${runtime}-TEXT";
                  executable = true;
                };
                ${sourceTarget}.content.source = ../../packages/kiro-cli/checks/fixtures/kiro-steering/alpha.md;
              };
            };
          };
          hm = (evalHm config).config;
          devenv = (evalDevenv config).config;
        in
          hm.home.file.${textTarget}.text
          == hm.ai.${runtime}.files.${textTarget}.content.text
          && devenv.files.${textTarget}.text == devenv.ai.${runtime}.files.${textTarget}.content.text
          && hm.home.file.${textTarget}.executable
          && devenv.files.${textTarget}.executable
          && hm.home.file.${sourceTarget}.source == ../../packages/kiro-cli/checks/fixtures/kiro-steering/alpha.md
          && devenv.files.${sourceTarget}.source == ../../packages/kiro-cli/checks/fixtures/kiro-steering/alpha.md
          && !(hm.home.file.${sourceTarget} ? text)
          && !(devenv.files.${sourceTarget} ? text);
      in
        lib.all checkRuntime harnessNames
    );

    module-runtime-files-disabled-runtime-does-not-emit = mkTest "runtime-files-disabled-runtime-does-not-emit" (
      let
        target = "literal/disabled.txt";
        config.ai.claude.files.${target}.content.text = "DECLARED-BUT-DISABLED";
        hm = (evalHm config).config;
        devenv = (evalDevenv config).config;
      in
        hm.ai.claude.files.${target}.content.text
        == "DECLARED-BUT-DISABLED"
        && !(hm.home.file ? ${target})
        && !(devenv.files ? ${target})
    );

    module-runtime-files-invalid-targets-rejected = mkTest "runtime-files-invalid-targets-rejected" (
      let
        rejected = target: let
          attempt = builtins.tryEval (let
            evaluated = evalHm {
              ai.claude.files.${target}.content.text = "invalid";
            };
          in
            builtins.deepSeq evaluated.config.ai.claude.files true);
        in
          !attempt.success;
      in
        lib.all rejected ["" "/absolute" "double//slash" "./dot" "parent/../escape"]
    );

    module-runtime-files-content-shape-rejected = mkTest "runtime-files-content-shape-rejected" (
      let
        disabled =
          (evalHm {
            ai.claude.files."literal/disabled".content.enable = false;
          }).config.ai.claude.files."literal/disabled";
        rejected = entry: let
          attempt = builtins.tryEval (let
            evaluated = evalHm {
              ai.claude.files."literal/invalid" = entry;
            };
          in
            builtins.deepSeq evaluated.config.ai.claude.files true);
        in
          !attempt.success;
      in
        # An explicit enable flag is the disabled shape, not a null sentinel.
        !disabled.content.enable
        # Equal-priority text and source are rejected by the shared
        # priority-aware text-source type.
        && rejected {
          content = {
            source = ../../packages/kiro-cli/checks/fixtures/kiro-steering/alpha.md;
            text = "both";
          };
        }
        # Delivery-specific alternatives remain exclusive with text/source and
        # with each other after the attrTag representation is removed.
        && rejected {
          content = {
            run = "printf probe";
            text = "both";
          };
        }
        && rejected {
          content = {
            run = "printf probe";
            value.probe = true;
          };
        }
        # The retired flat shape must not quietly keep working: an entry that
        # still says `text` at the top level has not been migrated, and
        # accepting it would deliver a file with no bytes.
        && rejected {text = "flat";}
    );

    module-runtime-files-generated-default-disable = mkTest "runtime-files-generated-default-disable" (
      let
        target = ".claude/CLAUDE.md";
        config.ai.claude = {
          enable = true;
          context.text = "GENERATED-CONTEXT";
          files.${target}.content.enable = false;
        };
        hm = (evalHm config).config;
        devenv = (evalDevenv config).config;
      in
        !hm.ai.claude.files.${target}.content.enable
        && !devenv.ai.claude.files.${target}.content.enable
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
            kiro.enable = true;
          };
        };
        hm = evalHm config;
        devenv = evalDevenv config;
        hmConfig = hm.config;
        devenvConfig = devenv.config;
      in
        hmConfig.ai.claude.files ? ".claude/CLAUDE.md"
        && hmConfig.ai.claude.files ? ".claude/rules/scoped.md"
        && hmConfig.ai.codex.files ? ".codex/AGENTS.md"
        && hmConfig.ai.kimchi.files ? ".config/kimchi/harness/AGENTS.md"
        && hmConfig.ai.kiro.files ? ".kiro/steering/AGENTS.md"
        && hmConfig.ai.kiro.files ? ".kiro/steering/scoped.md"
        && devenvConfig.ai.claude.files ? ".claude/CLAUDE.md"
        && devenvConfig.ai.claude.files ? ".claude/rules/scoped.md"
        && devenvConfig.ai.copilot.files ? ".github/copilot-instructions.md"
        && devenvConfig.ai.copilot.files ? ".github/instructions/scoped.instructions.md"
        && devenvConfig.ai.kimchi.files ? ".config/kimchi/harness/AGENTS.md"
        && devenvConfig.ai.kiro.files ? ".kiro/steering/scoped.md"
        && devenvConfig.ai.internal.files ? "AGENTS.md"
        && devenvConfig.ai.internal.files."AGENTS.md".content.text == devenvConfig.files."AGENTS.md".text
        && !(devenvConfig.files."AGENTS.md" ? source)
    );

    module-runtime-files-shared-agentsmd-arbitration = mkTest "runtime-files-shared-agentsmd-arbitration" (
      let
        base = {
          ai = {
            codex.enable = true;
            context.text = "GENERATED-SHARED-CONTEXT";
            kiro.enable = true;
          };
        };
        replaced = evalDevenv (lib.recursiveUpdate base {
          ai.codex.files."AGENTS.md".content.text = "CONSUMER-REPLACEMENT";
        });
        suppressed = evalDevenv (lib.recursiveUpdate base {
          ai.kiro.files."AGENTS.md".content.enable = false;
        });
        deduplicated = evalDevenv (lib.recursiveUpdate base {
          ai.codex.files."AGENTS.md".content.text = "SHARED-CONSUMER";
          ai.kiro.files."AGENTS.md".content.text = "SHARED-CONSUMER";
        });
        divergent = builtins.tryEval (let
          evaluated = evalDevenv (lib.recursiveUpdate base {
            ai.codex.files."AGENTS.md".content.text = "CODEX-CONSUMER";
            ai.kiro.files."AGENTS.md".content.text = "KIRO-CONSUMER";
          });
        in
          builtins.deepSeq evaluated.config.ai.internal.files."AGENTS.md" true);
      in
        replaced.config.ai.internal.files."AGENTS.md".content.text
        == "CONSUMER-REPLACEMENT"
        && replaced.config.files."AGENTS.md".text == "CONSUMER-REPLACEMENT"
        && !suppressed.config.ai.internal.files."AGENTS.md".content.enable
        && !(suppressed.config.files ? "AGENTS.md")
        && deduplicated.config.ai.internal.files."AGENTS.md".content.text == "SHARED-CONSUMER"
        && deduplicated.config.files."AGENTS.md".text == "SHARED-CONSUMER"
        && !divergent.success
    );

    module-runtime-files-shared-agentsmd-ignores-disabled-runtime = mkTest "runtime-files-shared-agentsmd-ignores-disabled-runtime" (
      let
        withDormantEntry = {
          activeRuntime,
          dormantRuntime,
          entry,
        }:
          evalDevenv {
            ai = {
              context.text = "ACTIVE-SHARED-CONTEXT";
              ${activeRuntime}.enable = true;
              ${dormantRuntime}.files."AGENTS.md" = entry;
            };
          };
        evaluations = [
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
          evaluated.config.files ? "AGENTS.md"
          && lib.hasInfix "ACTIVE-SHARED-CONTEXT" evaluated.config.files."AGENTS.md".text
          && !(lib.hasInfix "DORMANT-" evaluated.config.files."AGENTS.md".text))
        evaluations
    );

    module-runtime-files-size-guard-follows-final-entry = mkTest "runtime-files-size-guard-follows-final-entry" (
      let
        oversized = lib.concatStrings (lib.replicate 64 "x");
        hmReplacement = evalHm {
          ai.codex = {
            context.text = oversized;
            enable = true;
            files.".codex/AGENTS.md".content.text = "short";
            projectDocMaxBytes = 8;
          };
        };
        hmDisabled = evalHm {
          ai.codex = {
            context.text = oversized;
            enable = true;
            files.".codex/AGENTS.md".content.enable = false;
            projectDocMaxBytes = 8;
          };
        };
        devenvReplacement = evalDevenv {
          ai = {
            codex = {
              enable = true;
              files."AGENTS.md".content.text = "short";
              projectDocMaxBytes = 8;
            };
            context.text = oversized;
          };
        };
        devenvDisabled = evalDevenv {
          ai = {
            codex = {
              enable = true;
              files."AGENTS.md".content.enable = false;
              projectDocMaxBytes = 8;
            };
            context.text = oversized;
          };
        };
      in
        builtins.all (assertion: assertion.assertion) hmReplacement.config.assertions
        && builtins.all (assertion: assertion.assertion) hmDisabled.config.assertions
        && builtins.all (assertion: assertion.assertion) devenvReplacement.config.assertions
        && builtins.all (assertion: assertion.assertion) devenvDisabled.config.assertions
        && hmReplacement.config.home.file.".codex/AGENTS.md".text == "short"
        && !(hmDisabled.config.home.file ? ".codex/AGENTS.md")
        && devenvReplacement.config.files."AGENTS.md".text == "short"
        && !(devenvDisabled.config.files ? "AGENTS.md")
    );

    module-runtime-files-discarded-codex-source-stays-lazy = mkTest "runtime-files-discarded-codex-source-stays-lazy" (
      let
        source = pkgs.runCommand "discarded-codex-context-must-not-build" {} ''
          exit 1
        '';
        hmReplacement = evalHm {
          ai = {
            context = {inherit source;};
            codex = {
              context.text = "RUNTIME-CONTEXT";
              enable = true;
              files.".codex/AGENTS.md".content.text = "HM-REPLACEMENT";
            };
          };
        };
        hmDisabled = evalHm {
          ai = {
            context = {inherit source;};
            codex = {
              context.text = "RUNTIME-CONTEXT";
              enable = true;
              files.".codex/AGENTS.md".content.enable = false;
            };
          };
        };
        devenvReplacement = evalDevenv {
          ai = {
            context = {inherit source;};
            codex = {
              context.text = "RUNTIME-CONTEXT";
              enable = true;
              files."AGENTS.md".content.text = "DEVENV-REPLACEMENT";
            };
          };
        };
        devenvDisabled = evalDevenv {
          ai = {
            context = {inherit source;};
            codex = {
              context.text = "RUNTIME-CONTEXT";
              enable = true;
              files."AGENTS.md".content.enable = false;
            };
          };
        };
        hmKiroDisabled = evalHm {
          ai = {
            context = {inherit source;};
            kiro = {
              context.text = "RUNTIME-CONTEXT";
              enable = true;
              files.".kiro/steering/AGENTS.md".content.enable = false;
            };
          };
        };
        devenvKiroDisabled = evalDevenv {
          ai = {
            context = {inherit source;};
            kiro = {
              context.text = "RUNTIME-CONTEXT";
              enable = true;
              files."AGENTS.md".content.enable = false;
            };
          };
        };
      in
        hmReplacement.config.home.file.".codex/AGENTS.md".text
        == "HM-REPLACEMENT"
        && !(hmDisabled.config.home.file ? ".codex/AGENTS.md")
        && devenvReplacement.config.files."AGENTS.md".text == "DEVENV-REPLACEMENT"
        && !(devenvDisabled.config.files ? "AGENTS.md")
        && !(hmKiroDisabled.config.home.file ? ".kiro/steering/AGENTS.md")
        && !(devenvKiroDisabled.config.files ? "AGENTS.md")
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
            kiro.enable = true;
          };
        };
      in
        !(hmCodex.config.home.file ? ".codex/AGENTS.md")
        && !(devenvCodex.config.files ? "AGENTS.md")
        && !(devenvKiro.config.files ? "AGENTS.md")
    );

    # Content at `mkDefault` is still content: the leaf-default idiom a
    # downstream module uses for an overridable file must deliver it, not
    # leave a record that nothing writes and nothing reports.
    module-runtime-files-default-priority-content-delivers = mkTest "runtime-files-default-priority-content-delivers" (
      let
        source = ../../packages/kiro-cli/checks/fixtures/kiro-steering/alpha.md;
        config.ai.claude = {
          enable = true;
          files = {
            "literal/default-source.md".content.source = lib.mkDefault source;
            "literal/default-text.md".content.text = lib.mkDefault "DEFAULT-TEXT";
          };
        };
        delivered = sink: let
          field = target: name: (sink.${target} or {}).${name} or null;
        in
          field "literal/default-text.md" "text"
          == "DEFAULT-TEXT"
          && field "literal/default-source.md" "source" == source;
      in
        delivered (evalHm config).config.home.file
        && delivered (evalDevenv config).config.files
    );

    # Empty inline text is not content. An entry left with nothing else is
    # rejected rather than silently written as nothing; `enable = false` is
    # the deliberate way to keep an entry that delivers nothing.
    module-runtime-files-empty-text-rejected = mkTest "runtime-files-empty-text-rejected" (
      let
        attempt = evaluate: runtime: target: content:
          builtins.tryEval (builtins.deepSeq
            (lib.getAttrFromPath ["ai" runtime "files"]
              (evaluate {
                ai.${runtime} = {
                  enable = true;
                  files.${target}.content = content;
                };
              }).config)
            true);
        rejected = evaluate: runtime: target: content:
          !(attempt evaluate runtime target content).success;
        disabled = evalDevenv {
          ai.codex = {
            enable = true;
            files."AGENTS.md".content = {
              enable = false;
              text = "";
            };
          };
        };
      in
        rejected evalHm "claude" "literal/empty.md" {text = "";}
        && rejected evalDevenv "claude" "literal/empty.md" {text = "";}
        && rejected evalHm "claude" "literal/empty.md" {text = lib.mkDefault "";}
        && rejected evalDevenv "codex" "AGENTS.md" {text = "";}
        # Control: the same entry with content evaluates.
        && (attempt evalHm "claude" "literal/empty.md" {text = "PRESENT";}).success
        && !(disabled.config.files ? "AGENTS.md")
    );

    # `content.enable = false` is the one suppression lever, so it must reach
    # every content form. A `value` document or a `run` body that ignored it
    # would be written while the consumer's disable is accepted in silence.
    module-runtime-files-disable-suppresses-every-form = mkTest "runtime-files-disable-suppresses-every-form" (
      let
        runtimeFiles = import ../../lib/ai/runtime-files.nix {inherit lib;};
        target = ".kiro/probe.json";
        valueEntry = contents:
          lib.mkMerge ([
              {
                ai.kiro = {
                  enable = true;
                  files.${target}.format = "json";
                };
              }
            ]
            ++ map (content: {ai.kiro.files.${target}.content = content;}) contents);
        delivered = config:
          (evalHm config).config.home.file
          ? ${target}
          && (evalDevenv config).config.files ? ${target};
        suppressed = config:
          !((evalHm config).config.home.file ? ${target})
          && !((evalDevenv config).config.files ? ${target});
        runEntry = extra:
          (evalHm {
            ai.kiro = {
              enable = true;
              files.".kiro/probe.run".content = {run = "printf probe";} // extra;
            };
          }).config.ai.kiro.files.".kiro/probe.run";
      in
        # Control: an ordinary value document is delivered.
        delivered (valueEntry [{value.a = true;}])
        && suppressed (valueEntry [
          {
            enable = false;
            value.a = true;
          }
        ])
        # A generated leaf default, disabled by a separate consumer module.
        && suppressed (valueEntry [
          {value.a = lib.mkDefault true;}
          {enable = false;}
        ])
        && runtimeFiles.isLive (runEntry {})
        && !runtimeFiles.isLive (runEntry {enable = false;})
    );

    # A store-backed replacement of the shared AGENTS.md stays lazy: it is not
    # read to be measured against a size limit, which would build it during
    # evaluation. The source is a derivation that fails to build.
    module-runtime-files-shared-agentsmd-source-stays-lazy = mkTest "runtime-files-shared-agentsmd-source-stays-lazy" (
      let
        source = pkgs.runCommand "shared-agents-md-source-must-not-build" {} ''
          exit 1
        '';
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
        && toString evaluated.config.files."AGENTS.md".source == toString source
    );

    module-runtime-files-discarded-composed-context-stays-lazy = mkTest "runtime-files-discarded-composed-context-stays-lazy" (
      let
        source = pkgs.runCommand "discarded-runtime-contexts-must-not-build" {} ''
          exit 1
        '';
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
        devenvCopilot = evalDevenv {
          ai = {
            context = {inherit source;};
            copilot = {
              context.text = "RUNTIME-CONTEXT";
              enable = true;
              files.".github/copilot-instructions.md".content.text = "COPILOT-REPLACEMENT";
            };
          };
        };
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
              files.".config/kimchi/harness/AGENTS.md".content.text = "KIMCHI-REPLACEMENT";
            };
          };
        };
      in
        hmClaude.config.home.file.".claude/CLAUDE.md".text
        == "CLAUDE-REPLACEMENT"
        && devenvClaude.config.files.".claude/CLAUDE.md".text == "CLAUDE-REPLACEMENT"
        && devenvCopilot.config.files.".github/copilot-instructions.md".text == "COPILOT-REPLACEMENT"
        && hmKimchi.config.home.file.".config/kimchi/harness/AGENTS.md".text == "KIMCHI-REPLACEMENT"
        && devenvKimchi.config.files.".config/kimchi/harness/AGENTS.md".text == "KIMCHI-REPLACEMENT"
    );
  };
}
