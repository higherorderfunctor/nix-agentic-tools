# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode sembleignore
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) checkRows deliveredFiles deliveredMarkdown evalDevenv evalHm fromGeneratedTree markdownInput mkTest rejectsChange;
  inherit (import ../../packages/kiro-cli/checks/helpers.nix {inherit lib pkgs harness;}) kiroSteeringContent;

  aiCommon = import ../../lib/ai/ai-common.nix {inherit lib;};
  steeringDir = ../../packages/kiro-cli/checks/fixtures/kiro-steering;

  # `aiCommon.contentFileEntry` returns the delivery record wrapped in
  # `lib.mkDefault`, so a consumer can override what a factory contributed.
  # These assertions are about the arbitrated CONTENT, not the override
  # priority carrying it, so unwrap before comparing. Comparing the wrapper
  # directly would make every assertion below depend on the priority value.
  entryContent = entry: entry.content.content;
in {
  checks = {
    module-content-record-restrictions = mkTest "content-record-restrictions" (
      let
        text = "Consumer text.";
        source = steeringDir + "/alpha.md";
        rootContext = context: (evalHm {ai.context = context;}).config.ai.context;
        codexContext = context: (evalHm {ai.codex.context = context;}).config.ai.codex.context;
        sharedRule = example: (evalHm {ai.rules = {inherit example;};}).config.ai.rules.example;
        rejectsTwoSources = get:
          rejectsChange (input: (get input).text) {
            valid = {inherit text;};
            invalid = {inherit source text;};
            expected = text;
          };
        rejectsEmptyText = get: fields:
          rejectsChange (input: (get input).text) {
            valid = fields // {inherit text;};
            invalid = fields;
            expected = text;
          };
      in
        checkRows "content record restrictions" {
          "ai.codex.context rejects equal-priority source and text" = rejectsTwoSources codexContext;
          "ai.context rejects empty text when enabled" = rejectsEmptyText rootContext {enable = true;};
          "ai.context rejects equal-priority source and text" = rejectsTwoSources rootContext;
          "ai.rules rejects an empty matcher list" = rejectsChange (input: (sharedRule input).matcher) {
            valid = {
              inherit text;
              matcher = ["src/**"];
            };
            invalid = {
              inherit text;
              matcher = [];
            };
            expected = ["src/**"];
          };
          "ai.rules rejects empty text by default" = rejectsEmptyText sharedRule {};
          "ai.rules rejects empty text when explicitly enabled" = rejectsEmptyText sharedRule {enable = true;};
        }
    );

    module-content-record-text-writers-concatenate = mkTest "content-record-text-writers-concatenate" (
      let
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
        check = context: expectedText: let
          result = evalDevenv {
            ai.copilot = {
              github.context = context;
              enable = true;
            };
          };
          files = deliveredFiles result.config;
        in
          result.config.ai.copilot.github.context.text
          == expectedText
          && !(files ? "AGENTS.md")
          && !(files ? ".github/copilot-instructions.md");
        text = "Disabled content remains inspectable.";
      in
        checkRows "disabled Copilot context" {
          "disabled empty context emits neither instruction file" = check {enable = false;} "";
          "disabled inline context retains its text but emits neither file" =
            check {
              enable = false;
              inherit text;
            }
            text;
        }
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

    module-single-context-source-does-not-trigger-ifd = mkTest "single-context-source-does-not-trigger-ifd" (
      let
        source = pkgs.runCommand "context-source-must-not-build" {} ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
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
    );

    module-shared-agentsmd-tier-delivery = mkTest "shared-agentsmd-tier-delivery" (
      let
        base.ai = {
          codex.enable = true;
          rules = lib.genAttrs ["alpha" "beta"] (_: {
            matcher = ["src/**"];
            references = map (n: "docs/guidance/long-document-name-${n}.md") ["one" "two" "three" "four"];
            text = "RULE-BODY-MUST-NOT-BE-INLINED";
          });
        };
        active = evalDevenv base;
        childrenOf = result: lib.filter (path: lib.hasPrefix ".agents/rules/" path) (lib.attrNames (deliveredFiles result.config));
        child = ".agents/rules/guidance.md";
        disabled = evalDevenv (lib.recursiveUpdate base {ai.codex.files."AGENTS.md".enable = false;});
        replaced = evalDevenv (lib.recursiveUpdate base {ai.codex.files."AGENTS.md".content.text = "Consumer root.";});
        removed = evalDevenv {ai.codex.enable = true;};
        # An index can be inspected without reading a discarded context source.
        source = pkgs.runCommand "tier-discarded-context-must-not-build" {} ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          exit 1
        '';
        lazy = evalDevenv (lib.recursiveUpdate base {
          ai.context = {inherit source;};
          ai.codex.files."AGENTS.md".content.text = "Consumer root.";
        });
      in
        checkRows "shared AGENTS.md tier delivery" {
          "active index delivers its one child with relative links, not the rule body" =
            childrenOf active
            == [child]
            && active.config.ai.files.${child}.method == "ro"
            && lib.hasInfix "../../docs/guidance/" (deliveredMarkdown active child)
            && !(lib.hasInfix "RULE-BODY-MUST-NOT-BE-INLINED" (deliveredMarkdown active child));
          "child index cannot occupy another AGENTS.md target" = rejectsChange (config:
            (evalDevenv config).config.ai.internal._generatedFiles ? ${child}) {
            valid = base;
            invalid = lib.recursiveUpdate base {
              ai.internal.agentsMd.${child} = {
                hasContent = true;
                context = "Conflicting root.";
              };
            };
            expected = true;
          };
          "disabling the root hides its child" = childrenOf disabled == [];
          "no rules means no child" = childrenOf removed == [];
          "replacing the root hides its child" = childrenOf replaced == [];
          "replacing the root never reads a discarded source" =
            childrenOf lazy == [] && (deliveredFiles lazy.config)."AGENTS.md".text == "Consumer root.";
        }
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

    module-shared-agentsmd-rejects-divergent-contributions = mkTest "shared-agentsmd-rejects-divergent-contributions" (
      let
        shared = ai: (evalDevenv {inherit ai;}).config.ai.internal.agentsMd."AGENTS.md";
        inline = text: {
          codex.enable = true;
          kiro.cli.enable = true;
          kiro.rules.shared = {inherit text;};
          rules.shared.text = "Shared guidance.";
        };
        indexed = references: let
          scoped = {
            matcher = ["src/**"];
            references = ["source.md"];
            text = "Source guidance.";
          };
        in {
          codex.enable = true;
          kimchi.enable = true;
          kimchi.rules.scoped = scoped // {inherit references;};
          rules = {inherit scoped;};
        };
      in
        checkRows "shared AGENTS.md contribution restrictions" {
          "controls have both contributing runtimes" =
            (shared (inline "Shared guidance.")).audiences.shared
            == ["codex" "kiro"]
            && (shared (indexed ["source.md"])).audiences.scoped == ["codex" "kimchi"];
          "one index entry cannot have two reference lists" = rejectsChange (ai: (shared ai).index.scoped) {
            valid = indexed ["source.md"];
            invalid = indexed ["other.md"];
            expected = {
              description = "";
              inclusion = "fileMatch";
              matcher = ["src/**"];
              references = ["source.md"];
            };
          };
          "one inline rule key cannot have two bodies" = rejectsChange (ai: (shared ai).rules.shared) {
            valid = inline "Shared guidance.";
            invalid = inline "Kiro-only guidance.";
            expected = "Shared guidance.";
          };
        }
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
            rulesDir = steeringDir;
          };
        };
      in
        lib.attrNames (kiroSteeringContent result) == ["alpha.md" "beta.md" "gamma.md"]
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

    # Reads what the tree delivers, never `home.packages`: installing the package
    # reads no rules, so a probe on it passes on laziness alone.
    module-runtime-rules-deliver-markdown = mkTest "runtime-rules-deliver-markdown" (
      let
        claude = rules: evalHm {ai.claude = rules // {enable = true;};};
        kimchi = rules: evalHm {ai.kimchi = rules // {enable = true;};};
        dir = {rulesDir = steeringDir;};
        inline = {rules.test.text = "Runtime guidance.";};
        kimchiPath = ".config/kimchi/harness/AGENTS.md";
      in
        checkRows "runtime rules deliver Markdown" {
          "Claude renders every rule in its directory" = let
            result = claude dir;
            expected = {
              ".claude/rules/alpha.md" = "Alpha steering body.";
              ".claude/rules/beta.md" = "Beta steering body.";
              ".claude/rules/gamma.md" = "Gamma steering body.";
            };
            rulePaths = lib.filter (lib.hasPrefix ".claude/rules/") (lib.attrNames (deliveredFiles result.config));
          in
            rulePaths
            == lib.attrNames expected
            && lib.all (path: lib.hasInfix expected.${path} (deliveredMarkdown result path)) rulePaths;
          "Claude renders its named rule" = lib.hasInfix "Runtime guidance." (deliveredMarkdown (claude inline) ".claude/rules/test.md");
          "Kimchi renders every rule in its directory" = let
            agents = deliveredMarkdown (kimchi dir) kimchiPath;
          in
            lib.hasInfix "<!-- rule: alpha -->\n\nAlpha steering body." agents
            && lib.hasInfix "<!-- rule: beta -->\n\nBeta steering body." agents
            && lib.hasInfix "<!-- rule: gamma -->\n\nGamma steering body." agents
            && !(lib.hasInfix "<!-- rule: notes -->" agents);
          "Kimchi renders its named rule" = deliveredMarkdown (kimchi inline) kimchiPath == "<!-- rule: test -->\n\nRuntime guidance.";
        }
    );
  };
}
