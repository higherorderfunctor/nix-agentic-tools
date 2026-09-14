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
                  executable = true;
                  text = "${runtime}-TEXT";
                };
                ${sourceTarget}.source = ../../packages/kiro-cli/checks/fixtures/kiro-steering/alpha.md;
              };
            };
          };
          hm = (evalHm config).config;
          devenv = (evalDevenv config).config;
        in
          hm.home.file.${textTarget}.text
          == hm.ai.${runtime}.files.${textTarget}.text
          && devenv.files.${textTarget}.text == devenv.ai.${runtime}.files.${textTarget}.text
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
        config.ai.claude.files.${target}.text = "DECLARED-BUT-DISABLED";
        hm = (evalHm config).config;
        devenv = (evalDevenv config).config;
      in
        hm.ai.claude.files.${target}.text
        == "DECLARED-BUT-DISABLED"
        && !(hm.home.file ? ${target})
        && !(devenv.files ? ${target})
    );

    module-runtime-files-invalid-targets-rejected = mkTest "runtime-files-invalid-targets-rejected" (
      let
        rejected = target: let
          attempt = builtins.tryEval (let
            evaluated = evalHm {
              ai.claude.files.${target}.text = "invalid";
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
        rejected {}
        && rejected {
          source = ../../packages/kiro-cli/checks/fixtures/kiro-steering/alpha.md;
          text = "both";
        }
    );

    module-runtime-files-generated-default-tombstone = mkTest "runtime-files-generated-default-tombstone" (
      let
        target = ".claude/CLAUDE.md";
        config.ai.claude = {
          enable = true;
          context.text = "GENERATED-CONTEXT";
          files.${target} = null;
        };
        hm = (evalHm config).config;
        devenv = (evalDevenv config).config;
      in
        hm.ai.claude.files.${target}
        == null
        && devenv.ai.claude.files.${target} == null
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
            kimchi = {
              enable = true;
              rules.kimchi-only.text = "KIMCHI-RULE";
            };
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
        && devenvConfig.ai.internal.files ? "AGENTS.md"
        && devenvConfig.ai.kiro.files ? ".kiro/steering/scoped.md"
        && lib.hasInfix "KIMCHI-RULE" devenvConfig.ai.internal.files."AGENTS.md".text
        && devenvConfig.ai.internal.files."AGENTS.md".text == devenvConfig.files."AGENTS.md".text
        && !(devenvConfig.files."AGENTS.md" ? source)
    );

    module-runtime-files-shared-agentsmd-arbitration = mkTest "runtime-files-shared-agentsmd-arbitration" (
      let
        base = {
          ai = {
            codex.enable = true;
            context.text = "GENERATED-SHARED-CONTEXT";
            kimchi.enable = true;
            kiro.enable = true;
          };
        };
        runtimeNames = ["codex" "kimchi" "kiro"];
        replaced = map (runtime:
          evalDevenv (lib.recursiveUpdate base {
            ai.${runtime}.files."AGENTS.md".text = "CONSUMER-REPLACEMENT";
          }))
        runtimeNames;
        suppressed = map (runtime:
          evalDevenv (lib.recursiveUpdate base {
            ai.${runtime}.files."AGENTS.md" = null;
          }))
        runtimeNames;
        deduplicated = evalDevenv (lib.recursiveUpdate base {
          ai = {
            codex.files."AGENTS.md".text = "SHARED-CONSUMER";
            kimchi.files."AGENTS.md".text = "SHARED-CONSUMER";
            kiro.files."AGENTS.md".text = "SHARED-CONSUMER";
          };
        });
        divergent = builtins.tryEval (let
          evaluated = evalDevenv (lib.recursiveUpdate base {
            ai.codex.files."AGENTS.md".text = "CODEX-CONSUMER";
            ai.kimchi.files."AGENTS.md".text = "KIMCHI-CONSUMER";
          });
        in
          builtins.deepSeq evaluated.config.ai.internal.files."AGENTS.md" true);
      in
        lib.all (result:
          result.config.ai.internal.files."AGENTS.md".text
          == "CONSUMER-REPLACEMENT"
          && result.config.files."AGENTS.md".text == "CONSUMER-REPLACEMENT")
        replaced
        && lib.all (result:
          result.config.ai.internal.files."AGENTS.md"
          == null
          && !(result.config.files ? "AGENTS.md"))
        suppressed
        && deduplicated.config.ai.internal.files."AGENTS.md".text == "SHARED-CONSUMER"
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
        runtimeNames = ["codex" "kimchi" "kiro"];
        evaluations = lib.concatMap (activeRuntime:
          lib.concatMap (dormantRuntime:
            map (entry: withDormantEntry {inherit activeRuntime dormantRuntime entry;})
            [{text = "DORMANT-${dormantRuntime}";} null])
          (lib.filter (name: name != activeRuntime) runtimeNames))
        runtimeNames;
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
            files.".codex/AGENTS.md".text = "short";
            projectDocMaxBytes = 8;
          };
        };
        hmTombstone = evalHm {
          ai.codex = {
            context.text = oversized;
            enable = true;
            files.".codex/AGENTS.md" = null;
            projectDocMaxBytes = 8;
          };
        };
        devenvReplacement = evalDevenv {
          ai = {
            codex = {
              enable = true;
              files."AGENTS.md".text = "short";
              projectDocMaxBytes = 8;
            };
            context.text = oversized;
          };
        };
        devenvTombstone = evalDevenv {
          ai = {
            codex = {
              enable = true;
              files."AGENTS.md" = null;
              projectDocMaxBytes = 8;
            };
            context.text = oversized;
          };
        };
      in
        builtins.all (assertion: assertion.assertion) hmReplacement.config.assertions
        && builtins.all (assertion: assertion.assertion) hmTombstone.config.assertions
        && builtins.all (assertion: assertion.assertion) devenvReplacement.config.assertions
        && builtins.all (assertion: assertion.assertion) devenvTombstone.config.assertions
        && hmReplacement.config.home.file.".codex/AGENTS.md".text == "short"
        && !(hmTombstone.config.home.file ? ".codex/AGENTS.md")
        && devenvReplacement.config.files."AGENTS.md".text == "short"
        && !(devenvTombstone.config.files ? "AGENTS.md")
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
              files.".codex/AGENTS.md".text = "HM-REPLACEMENT";
            };
          };
        };
        hmTombstone = evalHm {
          ai = {
            context = {inherit source;};
            codex = {
              context.text = "RUNTIME-CONTEXT";
              enable = true;
              files.".codex/AGENTS.md" = null;
            };
          };
        };
        devenvReplacement = evalDevenv {
          ai = {
            context = {inherit source;};
            codex = {
              context.text = "RUNTIME-CONTEXT";
              enable = true;
              files."AGENTS.md".text = "DEVENV-REPLACEMENT";
            };
          };
        };
        devenvTombstone = evalDevenv {
          ai = {
            context = {inherit source;};
            codex = {
              context.text = "RUNTIME-CONTEXT";
              enable = true;
              files."AGENTS.md" = null;
            };
          };
        };
        hmKiroTombstone = evalHm {
          ai = {
            context = {inherit source;};
            kiro = {
              context.text = "RUNTIME-CONTEXT";
              enable = true;
              files.".kiro/steering/AGENTS.md" = null;
            };
          };
        };
        devenvKiroTombstone = evalDevenv {
          ai = {
            context = {inherit source;};
            kiro = {
              context.text = "RUNTIME-CONTEXT";
              enable = true;
              files."AGENTS.md" = null;
            };
          };
        };
      in
        hmReplacement.config.home.file.".codex/AGENTS.md".text
        == "HM-REPLACEMENT"
        && !(hmTombstone.config.home.file ? ".codex/AGENTS.md")
        && devenvReplacement.config.files."AGENTS.md".text == "DEVENV-REPLACEMENT"
        && !(devenvTombstone.config.files ? "AGENTS.md")
        && !(hmKiroTombstone.config.home.file ? ".kiro/steering/AGENTS.md")
        && !(devenvKiroTombstone.config.files ? "AGENTS.md")
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
        explicitEmpty = evalDevenv {
          ai.codex = {
            enable = true;
            files."AGENTS.md".text = "";
          };
        };
      in
        !(hmCodex.config.home.file ? ".codex/AGENTS.md")
        && !(devenvCodex.config.files ? "AGENTS.md")
        && !(devenvKiro.config.files ? "AGENTS.md")
        && explicitEmpty.config.files."AGENTS.md".text == ""
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
              files.".claude/CLAUDE.md".text = "CLAUDE-REPLACEMENT";
            };
          };
        };
        devenvClaude = evalDevenv {
          ai = {
            context = {inherit source;};
            claude = {
              context.text = "RUNTIME-CONTEXT";
              enable = true;
              files.".claude/CLAUDE.md".text = "CLAUDE-REPLACEMENT";
            };
          };
        };
        devenvCopilot = evalDevenv {
          ai = {
            context = {inherit source;};
            copilot = {
              context.text = "RUNTIME-CONTEXT";
              enable = true;
              files.".github/copilot-instructions.md".text = "COPILOT-REPLACEMENT";
            };
          };
        };
        hmKimchi = evalHm {
          ai = {
            context = {inherit source;};
            kimchi = {
              context.text = "RUNTIME-CONTEXT";
              enable = true;
              files.".config/kimchi/harness/AGENTS.md".text = "KIMCHI-REPLACEMENT";
            };
          };
        };
        devenvKimchi = evalDevenv {
          ai = {
            context = {inherit source;};
            kimchi = {
              context.text = "RUNTIME-CONTEXT";
              enable = true;
              files."AGENTS.md".text = "KIMCHI-REPLACEMENT";
            };
          };
        };
      in
        hmClaude.config.home.file.".claude/CLAUDE.md".text
        == "CLAUDE-REPLACEMENT"
        && devenvClaude.config.files.".claude/CLAUDE.md".text == "CLAUDE-REPLACEMENT"
        && devenvCopilot.config.files.".github/copilot-instructions.md".text == "COPILOT-REPLACEMENT"
        && hmKimchi.config.home.file.".config/kimchi/harness/AGENTS.md".text == "KIMCHI-REPLACEMENT"
        && devenvKimchi.config.files."AGENTS.md".text == "KIMCHI-REPLACEMENT"
    );
  };
}
