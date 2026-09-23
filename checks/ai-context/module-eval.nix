# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode sembleignore
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) evalDevenv evalHm mkTest ownPlan;
  inherit (import ../../packages/kiro-cli/checks/helpers.nix {inherit lib pkgs harness;}) kiroSteeringContent;

  # `aiCommon.contentFileEntry` returns the delivery record wrapped in
  # `lib.mkDefault`, so a consumer can override what a factory contributed.
  # These assertions are about the arbitrated CONTENT, not the override
  # priority carrying it, so unwrap before comparing. Comparing the wrapper
  # directly would make every assertion below depend on the priority value.
  entryContent = entry: entry.content.content;
in {
  checks = {
    module-context-content-record-rejects-two-sources = mkTest "context-content-record-rejects-two-sources" (!(builtins.tryEval (let
      result = evalHm {
        ai.context = {
          source = ../../packages/kiro-cli/checks/fixtures/kiro-steering/alpha.md;
          text = "two sources";
        };
      };
    in
      builtins.deepSeq result.config.ai.context true)).success);

    module-runtime-context-record-rejects-two-sources = mkTest "runtime-context-record-rejects-two-sources" (!(builtins.tryEval (let
      result = evalHm {
        ai.codex.context = {
          source = ../../packages/kiro-cli/checks/fixtures/kiro-steering/alpha.md;
          text = "two sources";
        };
      };
    in
      builtins.deepSeq result.config.ai.codex.context true)).success);

    module-content-record-text-writers-concatenate = mkTest "content-record-text-writers-concatenate" (
      let
        aiCommon = import ../../lib/ai/ai-common.nix {inherit lib;};
        context =
          (lib.evalModules {
            modules = [
              {
                options.context = lib.mkOption {
                  type = aiCommon.optionalContentModule;
                  default = {};
                };
              }
              {context.text = "first writer";}
              {context.text = "second writer";}
            ];
          }).config.context;
        rules =
          (lib.evalModules {
            modules = [
              {
                options.rules = lib.mkOption {
                  type = lib.types.attrsOf aiCommon.ruleModule;
                  default = {};
                };
              }
              {rules.same.text = "first writer";}
              {rules.same.text = "second writer";}
            ];
          }).config.rules;
      in
        context.text
        == "first writer\nsecond writer"
        && rules.same.text == "first writer\nsecond writer"
    );

    module-rule-content-priority-arbitrates = mkTest "rule-content-priority-arbitrates" (
      let
        aiCommon = import ../../lib/ai/ai-common.nix {inherit lib;};
        result = lib.evalModules {
          modules = [
            {
              options.rules = lib.mkOption {
                type = lib.types.attrsOf aiCommon.ruleModule;
                default = {};
              };
            }
            {rules.example.source = lib.mkDefault ../../lib/ai/types.nix;}
            {rules.example.text = "Consumer rule.";}
          ];
        };
        rule = result.config.rules.example;
      in
        rule.source
        == ../../lib/ai/types.nix
        && rule.text == "Consumer rule."
        && entryContent (aiCommon.contentFileEntry rule)
        == {
          enable = true;
          text = "Consumer rule.";
        }
    );

    module-rule-disable-omits-every-runtime-output = mkTest "rule-disable-omits-every-runtime-output" (
      let
        activeMarker = "ACTIVE-RULE-MUST-BE-EMITTED";
        disabledMarker = "DISABLED-RULE-MUST-NOT-BE-EMITTED";
        config = {
          ai = {
            claude.enable = true;
            codex.enable = true;
            copilot.enable = true;
            kimchi.enable = true;
            kiro.enable = true;
            rules.active = {
              matcher = ["**/*.nix"];
              text = activeMarker;
            };
            rules.disabled = {
              matcher = ["**/*.nix"];
              text = disabledMarker;
            };
            claude.rules.disabled.enable = false;
            codex.rules.disabled.enable = false;
            copilot.rules.disabled.enable = false;
            kiro.rules.disabled.enable = false;
          };
        };
        hmFiles = (evalHm config).config.home.file;
        devenv = evalDevenv config;
        # Claude's project rules are read-only copies; lay the copy writer's
        # units over the linked files so one predicate reads both backends.
        devenvFiles =
          devenv.config.files
          // lib.mapAttrs' (name: unit: lib.nameValuePair ".claude/rules/${name}" unit)
          (lib.head (ownPlan "claude" "ai:claude:materialize-rules" devenv).targets).units;
        outputsAreCorrect = agentsPath: files:
          files ? ".claude/rules/active.md"
          && files ? ".kiro/steering/active.md"
          && lib.hasInfix activeMarker (files.${agentsPath}.text or "")
          && !(files ? ".claude/rules/disabled.md")
          && !(files ? ".github/instructions/disabled.instructions.md")
          && !(files ? ".kiro/steering/disabled.md")
          && !(lib.hasInfix disabledMarker (files.${agentsPath}.text or ""));
      in
        outputsAreCorrect ".codex/AGENTS.md" hmFiles
        && outputsAreCorrect "AGENTS.md" devenvFiles
        && devenvFiles ? ".github/instructions/active.instructions.md"
    );

    module-disabled-empty-context-omits-output = mkTest "disabled-empty-context-omits-output" (
      let
        empty = evalDevenv {
          ai.copilot = {
            context.enable = false;
            enable = true;
          };
        };
        withContent = evalDevenv {
          ai.copilot = {
            context = {
              enable = false;
              text = "Disabled content remains inspectable.";
            };
            enable = true;
          };
        };
      in
        empty.config.ai.copilot.context.text
        == ""
        && !(empty.config.files ? ".github/copilot-instructions.md")
        && withContent.config.ai.copilot.context.text == "Disabled content remains inspectable."
        && !(withContent.config.files ? ".github/copilot-instructions.md")
    );

    module-text-source-force-empty-disables = mkTest "text-source-force-empty-disables" (
      let
        aiTypes = import ../../lib/ai/types.nix {inherit lib;};
        result = lib.evalModules {
          modules = [
            {
              options.value = lib.mkOption {
                type = aiTypes.optionalTextSource {description = "test content";};
              };
            }
            {value.source = ../../lib/ai/types.nix;}
            {value.text = lib.mkForce "";}
          ];
        };
      in
        !result.config.value.enable && result.config.value.text == ""
    );

    module-null-source-winner-keeps-text = mkTest "null-source-winner-keeps-text" (
      let
        aiCommon = import ../../lib/ai/ai-common.nix {inherit lib;};
        result = lib.evalModules {
          modules = [
            {
              options.value = lib.mkOption {
                type = aiCommon.optionalContentModule;
                default = {};
              };
            }
            {value.source = lib.mkForce null;}
            {value.text = "Consumer text.";}
          ];
        };
        value = result.config.value;
      in
        value.text
        == "Consumer text."
        && aiCommon.hasContent value
        && entryContent (aiCommon.contentFileEntry value)
        == {
          enable = true;
          text = "Consumer text.";
        }
    );

    module-rule-rejects-empty-content = mkTest "rule-rejects-empty-content" (!(builtins.tryEval (let
      aiCommon = import ../../lib/ai/ai-common.nix {inherit lib;};
      result = lib.evalModules {
        modules = [
          {
            options.rules = lib.mkOption {
              type = lib.types.attrsOf aiCommon.ruleModule;
              default = {};
            };
          }
          {rules.example = {};}
        ];
      };
    in
      builtins.deepSeq result.config.rules.example true)).success);

    module-enabled-rule-rejects-empty-content = mkTest "enabled-rule-rejects-empty-content" (
      let
        evaluated = evalHm {};
        ruleOptions = evaluated.options.ai.rules.type.nestedTypes.elemType.getSubOptions [];
        enableExists = ruleOptions ? enable;
        contextRejected =
          !(builtins.tryEval (let
            result = evalHm {ai.context.enable = true;};
          in
            builtins.deepSeq result.config.ai.context true)).success;
        ruleRejected =
          !(builtins.tryEval (let
            result = evalHm {ai.rules.example.enable = true;};
          in
            builtins.deepSeq result.config.ai.rules.example true)).success;
      in
        enableExists && contextRejected && ruleRejected
    );

    module-single-context-source-does-not-trigger-ifd = mkTest "single-context-source-does-not-trigger-ifd" (
      let
        source = pkgs.runCommand "context-source-must-not-build" {} ''
          exit 1
        '';
        result = evalDevenv {
          ai.copilot = {
            context = {inherit source;};
            enable = true;
          };
        };
        entry = result.config.files.".github/copilot-instructions.md";
      in
        entry.source == source && !(entry ? text)
    );

    module-rule-rejects-empty-matcher = mkTest "rule-rejects-empty-matcher" (!(builtins.tryEval (let
      result = evalHm {
        ai.rules.empty-matcher = {
          matcher = [];
          text = "ambiguous";
        };
      };
    in
      builtins.deepSeq result.config.ai.rules.empty-matcher true)).success);

    module-shared-agentsmd-dedupes-identical-units = mkTest "shared-agentsmd-dedupes-identical-units" (
      let
        result = evalDevenv {
          ai = {
            codex.enable = true;
            context.text = "Shared context.";
            kiro.enable = true;
            rules.shared.text = "Shared rule.";
          };
        };
        agents = result.config.files."AGENTS.md".text;
      in
        agents
        == "Shared context.\n\n<!-- rule: shared -->\nShared rule."
        && !(lib.hasInfix "---" agents)
    );

    module-shared-agentsmd-rejects-divergent-units = mkTest "shared-agentsmd-rejects-divergent-units" (
      let
        attempt = builtins.tryEval (let
          result = evalDevenv {
            ai = {
              codex = {
                enable = true;
                rules.shared.text = "Codex view.";
              };
              kiro = {
                enable = true;
                rules.shared.text = "Kiro view.";
              };
            };
          };
        in
          builtins.deepSeq result.config.files."AGENTS.md" true);
      in
        !attempt.success
    );

    module-shared-agentsmd-omits-absent-runtime-context = mkTest "shared-agentsmd-omits-absent-runtime-context" (
      let
        result = evalDevenv {
          ai = {
            codex = {
              context.text = "Codex-only context.";
              enable = true;
            };
            kiro = {
              enable = true;
              rules.kiro-only.text = "Kiro rule.";
            };
          };
        };
        agents = result.config.files."AGENTS.md".text;
      in
        lib.hasInfix "Codex-only context." agents
        && lib.hasInfix "Kiro rule." agents
    );

    # Top-level `ai.rulesDir` fans out to every enabled CLI via the
    # sharedOptions L1→L2 expansion.
    module-top-level-rulesdir-fans-out-to-kiro = mkTest "top-level-rulesdir-fans-out-to-kiro" (
      let
        result = evalHm {
          ai = {
            kiro.enable = true;
            rulesDir = ../../packages/kiro-cli/checks/fixtures/kiro-steering;
          };
        };
      in
        (kiroSteeringContent result) ? "alpha.md"
    );

    # Top-level `ai.skillsDir` fans out to every enabled CLI.
    module-top-level-skillsdir-fans-out-to-claude = mkTest "top-level-skillsdir-fans-out-to-claude" (
      let
        result = evalHm {
          ai = {
            claude.enable = true;
            skillsDir = ../../packages/claude-code/checks/fixtures/claude-skills;
          };
        };
        upstream = result.config.programs.claude-code.skills or {};
      in
        upstream ? skill-a && upstream ? skill-b
    );

    module-ai-rules-accepted-for-claude = mkTest "ai-rules-accepted-for-claude" (
      let
        probe =
          builtins.tryEval
          (evalHm {
            ai.claude = {
              enable = true;
              rules.test.text = "test";
            };
          })
      .config.home.packages;
      in
        probe.success
    );

    module-ai-rules-excluded-for-kimchi = mkTest "ai-rules-excluded-for-kimchi" (
      let
        probe =
          builtins.tryEval
          (evalHm {
            ai.kimchi = {
              enable = true;
              rules.test.text = "test";
            };
          })
      .config.home.packages;
      in
        !probe.success
    );

    module-ai-rules-root-degrades-for-kimchi = mkTest "ai-rules-root-degrades-for-kimchi" (
      let
        result = evalHm {
          ai.kimchi.enable = true;
          ai.rules.test.text = "test";
        };
      in
        builtins.length result.config.home.packages
        == 1
        && !(result.config.ai.kimchi ? rules)
    );

    # A REAL directory, not `../fixtures`, which never existed. Both probes
    # used to pass on laziness alone: nothing forced the fanout, so the
    # accepted arm proved only that `home.packages` did not read it. Hosting a
    # delivery `upstream` sink under `programs` made that read eager — see the
    # `upstreamRoots` table in lib/ai/deliver.nix — and the arm started
    # failing on the missing path rather than on its own claim.
    module-ai-rules-dir-accepted-for-claude = mkTest "ai-rules-dir-accepted-for-claude" (
      let
        probe =
          builtins.tryEval
          (evalHm {
            ai.claude = {
              enable = true;
              rulesDir = ../../packages/kiro-cli/checks/fixtures/kiro-steering;
            };
          })
      .config.home.packages;
      in
        probe.success
    );

    module-ai-rules-dir-excluded-for-kimchi = mkTest "ai-rules-dir-excluded-for-kimchi" (
      let
        probe =
          builtins.tryEval
          (evalHm {
            ai.kimchi = {
              enable = true;
              rulesDir = ../../packages/kiro-cli/checks/fixtures/kiro-steering;
            };
          })
      .config.home.packages;
      in
        !probe.success
    );

    # Top-level `ai.agentsDir` fans out to every enabled agent-
    # consumer (Claude, Copilot — NOT kiro).
    module-top-level-agentsdir-fans-out-to-claude = mkTest "top-level-agentsdir-fans-out-to-claude" (
      let
        result = evalHm {
          ai = {
            claude.enable = true;
            agentsDir = ../../packages/claude-code/checks/fixtures/claude-agents;
          };
        };
        upstream = result.config.programs.claude-code.agents or {};
      in
        upstream ? agent-one && upstream ? agent-two
    );
  };
}
