# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode sembleignore
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) deliveredFiles evalDevenv evalHm fromGeneratedTree markdownInput mkTest;
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
          _generated = true;
          _surface = "context";
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
            kiro.cli.enable = true;
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
            copilot.github.rules.disabled.enable = false;
            kimchi.rules.disabled.enable = false;
            kiro.rules.disabled.enable = false;
          };
        };
        hm = evalHm config;
        devenv = evalDevenv config;
        # Several devenv outputs are read-only copies (Claude rules, Copilot
        # instructions, Kiro steering, AGENTS.md); read what reaches the tree
        # so one predicate covers both backends.
        devenvFiles = deliveredFiles devenv.config;
        outputsAreCorrect = evaluated: agentsPath: files: let
          agents = (markdownInput evaluated agentsPath).text;
        in
          files ? ".claude/rules/active.md"
          && files ? ".kiro/steering/active.md"
          && fromGeneratedTree agentsPath files.${agentsPath}
          && lib.hasInfix activeMarker agents
          && !(files ? ".claude/rules/disabled.md")
          && !(files ? ".github/instructions/disabled.instructions.md")
          && !(files ? ".kiro/steering/disabled.md")
          && !(lib.hasInfix disabledMarker agents);
      in
        outputsAreCorrect hm ".codex/AGENTS.md" hm.config.home.file
        && outputsAreCorrect devenv "AGENTS.md" devenvFiles
        && devenvFiles ? ".github/instructions/active.instructions.md"
    );

    module-disabled-empty-context-omits-output = mkTest "disabled-empty-context-omits-output" (
      let
        empty = evalDevenv {
          ai.copilot = {
            github.context.enable = false;
            enable = true;
          };
        };
        withContent = evalDevenv {
          ai.copilot = {
            github.context = {
              enable = false;
              text = "Disabled content remains inspectable.";
            };
            enable = true;
          };
        };
      in
        empty.config.ai.copilot.github.context.text
        == ""
        && !((deliveredFiles empty.config) ? "AGENTS.md")
        && withContent.config.ai.copilot.github.context.text == "Disabled content remains inspectable."
        && !((deliveredFiles withContent.config) ? "AGENTS.md")
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
          _generated = true;
          _surface = "context";
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
          ai.claude = {
            context = {inherit source;};
            enable = true;
          };
        };
        entry = (deliveredFiles result.config).".claude/CLAUDE.md";
        input = markdownInput result ".claude/CLAUDE.md";
      in
        # Delivered from the Markdown tree, which takes the source as it is:
        # the tree's derivation names it, and nothing reads its bytes.
        fromGeneratedTree ".claude/CLAUDE.md" entry
        && !(entry ? text)
        && toString input.source == toString source
        && !(input ? text)
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
            kiro.cli.enable = true;
            rules.shared.text = "Shared rule.";
          };
        };
        agents = (markdownInput result "AGENTS.md").text;
      in
        fromGeneratedTree "AGENTS.md" (deliveredFiles result.config)."AGENTS.md"
        && agents
        == "<!-- rule: shared -->\n\nApply this rule only in: `codex`, `kiro`.\n\nShared rule.\n\nShared context."
        && result.config.ai.internal.agentsMd."AGENTS.md".audiences.shared == ["codex" "kiro"]
        && !(lib.hasInfix "---" agents)
    );

    module-shared-agentsmd-preserves-rule-audiences = mkTest "shared-agentsmd-preserves-rule-audiences" (
      let
        result = evalDevenv {
          ai = {
            claude.enable = true;
            codex.enable = true;
            copilot.enable = true;
            kimchi.enable = true;
            kiro.cli.enable = true;
            rules = {
              automatic = {
                description = "Use for deployment planning.";
                inclusion = ["auto" "fileMatch"];
                matcher = ["deploy/**"];
                references = ["docs/deploy.md"];
                text = "Deployment guidance.";
              };
              inline.text = "Inline guidance.";
              manual = {
                inclusion = ["manual" "fileMatch"];
                matcher = ["ops/**"];
                references = ["docs/ops.md"];
                text = "Operations guidance.";
              };
              scoped = {
                matcher = ["src/**"];
                references = ["docs/source.md"];
                text = "Source guidance.";
              };
            };
            codex.rules.manual.enable = false;
            copilot.github.rules.scoped.enable = false;
            kimchi.rules.inline.enable = false;
          };
        };
        shared = result.config.ai.internal.agentsMd."AGENTS.md";
        agents = (markdownInput result "AGENTS.md").text;
        files = deliveredFiles result.config;
        claude = (markdownInput result ".claude/rules/scoped.md").text;
      in
        shared.audiences.automatic
        == ["codex" "kimchi"]
        && shared.audiences.inline == ["codex" "kiro"]
        && shared.audiences.manual == ["kimchi"]
        && shared.audiences.scoped == ["codex" "kimchi"]
        && shared.index.automatic
        == {
          description = "Use for deployment planning.";
          inclusion = "auto";
          matcher = ["deploy/**"];
          references = ["docs/deploy.md"];
        }
        && shared.index.manual.inclusion == "manual"
        && shared.index.scoped.inclusion == "fileMatch"
        && lib.hasInfix "Runtimes with native rule injection already receive their applicable" agents
        && lib.hasInfix "  - Audience: `kimchi`\n" agents
        && lib.hasInfix "Apply this rule only in: `codex`, `kiro`.\n\nInline guidance." agents
        && lib.hasInfix "paths:" claude
        && lib.hasInfix "Source guidance." claude
        && !(lib.hasInfix "Audience:" claude)
        && !(files ? ".github/instructions/scoped.instructions.md")
        && files ? ".github/instructions/manual.instructions.md"
        && files ? ".kiro/steering/scoped.md"
    );

    module-shared-agentsmd-rejects-divergent-index = mkTest "shared-agentsmd-rejects-divergent-index" (
      let
        attempt = builtins.tryEval (let
          result = evalDevenv {
            ai = {
              codex.enable = true;
              kimchi = {
                enable = true;
                rules.scoped = {
                  matcher = ["other/**"];
                  references = ["other.md"];
                  text = "Other guidance.";
                };
              };
              rules.scoped = {
                matcher = ["src/**"];
                references = ["source.md"];
                text = "Source guidance.";
              };
            };
          };
        in
          builtins.deepSeq (markdownInput result "AGENTS.md").text true);
      in
        !attempt.success
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
                cli.enable = true;
                rules.shared.text = "Kiro view.";
              };
            };
          };
        in
          builtins.deepSeq (deliveredFiles result.config)."AGENTS.md" true);
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
              cli.enable = true;
              rules.kiro-only.text = "Kiro rule.";
            };
          };
        };
        agents = (markdownInput result "AGENTS.md").text;
      in
        fromGeneratedTree "AGENTS.md" (deliveredFiles result.config)."AGENTS.md"
        && lib.hasInfix "Codex-only context." agents
        && lib.hasInfix "Kiro rule." agents
    );

    # Top-level `ai.rulesDir` fans out to every enabled CLI via the
    # sharedOptions L1→L2 expansion.
    module-top-level-rulesdir-fans-out-to-kiro = mkTest "top-level-rulesdir-fans-out-to-kiro" (
      let
        result = evalHm {
          ai = {
            kiro.cli.enable = true;
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
        files = result.config.home.file;
      in
        files ? ".claude/skills/skill-a/SKILL.md" && files ? ".claude/skills/skill-b/SKILL.md"
    );

    # The accepted arms force the delivered file map, never `home.packages`:
    # nothing about installing the package reads the rules, so a probe on it
    # passes on laziness alone.
    module-ai-rules-accepted-for-claude = mkTest "ai-rules-accepted-for-claude" (
      let
        probe = builtins.tryEval (lib.attrNames
          (evalHm {
            ai.claude = {
              enable = true;
              rules.test.text = "test";
            };
          })
          .config
          .home
          .file);
      in
        probe.success
    );

    module-ai-rules-accepted-for-kimchi = mkTest "ai-rules-accepted-for-kimchi" (
      let
        probe = builtins.tryEval (lib.attrNames
          (evalHm {
            ai.kimchi = {
              enable = true;
              rules.test.text = "test";
            };
          })
          .config
          .home
          .file);
      in
        probe.success
    );

    module-ai-rules-root-fans-out-to-kimchi = mkTest "ai-rules-root-fans-out-to-kimchi" (
      let
        result = evalHm {
          ai.kimchi.enable = true;
          ai.rules.test.text = "test";
        };
      in
        builtins.length result.config.home.packages
        == 1
        && result.config.ai.kimchi ? rules
        && (markdownInput result ".config/kimchi/harness/AGENTS.md").text
        == "<!-- rule: test -->\n\ntest"
    );

    # A REAL directory, not `../fixtures`, which never existed: with a probe on
    # `home.packages` it passed on laziness alone, because nothing forced the
    # fanout. Forcing the file map makes it fail on a missing path.
    module-ai-rules-dir-accepted-for-claude = mkTest "ai-rules-dir-accepted-for-claude" (
      let
        probe = builtins.tryEval (lib.attrNames
          (evalHm {
            ai.claude = {
              enable = true;
              rulesDir = ../../packages/kiro-cli/checks/fixtures/kiro-steering;
            };
          })
          .config
          .home
          .file);
      in
        probe.success
    );

    module-ai-rules-dir-accepted-for-kimchi = mkTest "ai-rules-dir-accepted-for-kimchi" (
      let
        probe = builtins.tryEval (lib.attrNames
          (evalHm {
            ai.kimchi = {
              enable = true;
              rulesDir = ../../packages/kiro-cli/checks/fixtures/kiro-steering;
            };
          })
          .config
          .home
          .file);
      in
        probe.success
    );
  };
}
