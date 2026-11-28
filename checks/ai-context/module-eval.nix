# End-to-end module contracts; the shared harness discovers every backend.
# cspell:ignore batchmode sembleignore
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) checkRows deliveredFiles deliveredMarkdown evalDevenv evalHm evalHmModules fromGeneratedTree hasLiteral markdownInput mkTest rejectsChange;
  inherit (import ../../packages/kiro-cli/checks/helpers.nix {inherit lib pkgs harness;}) kiroSteeringContent;

  steeringDir = ../../packages/kiro-cli/checks/fixtures/kiro-steering;

  claudeContext = ".claude/CLAUDE.md";
  kimchiAgents = ".config/kimchi/harness/AGENTS.md";
  unbuildable = name:
    pkgs.runCommand name {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      echo "This source must not be built: ${name}" >&2
      exit 1
    '';
in {
  checks = {
    module-content-record-restrictions = mkTest "content-record-restrictions" (
      let
        text = "Consumer text.";
        source = steeringDir + "/alpha.md";
        rootContext = context: (evalHm {ai.context = context;}).config.ai.context;
        sharedRule = example: (evalHm {ai.rules = {inherit example;};}).config.ai.rules.example;
        # Force only the field that owns the restriction. Each invalid input
        # changes only the value or adds the competing definition.
        rejectsEmptyText = get: fields:
          rejectsChange (input: (get input).text) {
            valid = fields // {inherit text;};
            invalid = fields;
            expected = text;
          };
      in
        checkRows "content record restrictions" {
          "ai.context rejects empty text when enabled" = rejectsEmptyText rootContext {enable = true;};
          "ai.context rejects equal-priority source and text" = rejectsChange (input: (rootContext input).text) {
            valid = {inherit text;};
            invalid = {inherit source text;};
            expected = text;
          };
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
          "ai.rules rejects empty text without an enable setting because rules default to enabled" = rejectsEmptyText sharedRule {};
        }
    );

    module-content-record-text-writers-concatenate = mkTest "content-record-text-writers-concatenate" (
      let
        merged =
          (evalHmModules [
            {
              ai.context.text = "first writer";
              ai.rules.same.text = "first writer";
            }
            {
              ai.context.text = "second writer";
              ai.rules.same.text = "second writer";
            }
          ]).config.ai;
      in
        checkRows "same-priority text writers" {
          "root context does not replace or reorder the first writer" = merged.context.text == "first writer\nsecond writer";
          "the keyed rule merge does not replace or reorder the first writer" = merged.rules.same.text == "first writer\nsecond writer";
        }
    );

    # A losing source may stay in the record, but must not supply the delivered rule.
    module-rule-content-priority-arbitrates = mkTest "rule-content-priority-arbitrates" (
      let
        result = evalHmModules [
          {
            ai.claude.enable = true;
            ai.rules.example.source = lib.mkDefault (steeringDir + "/alpha.md");
          }
          {ai.rules.example.text = "Consumer rule.";}
        ];
      in
        deliveredMarkdown result ".claude/rules/example.md" == "Consumer rule."
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
            kimchi.rules.disabled.enable = false;
            kiro.rules.disabled.enable = false;
          };
        };
        hm = evalHm config;
        devenv = evalDevenv config;
        # Check the actual steering destinations, not just the input rules.
        kiroFiles = deliveredFiles hm.config;
        composedRule = evaluated: path: let
          agents = deliveredMarkdown evaluated path;
        in
          hasLiteral activeMarker agents && !(hasLiteral disabledMarker agents);
      in
        checkRows "runtime rule suppression" {
          "devenv shared AGENTS.md excludes the suppressed rule body" = composedRule devenv "AGENTS.md";
          "home-manager Kimchi does not include the suppressed rule in its own AGENTS.md" = composedRule hm kimchiAgents;
          "home-manager Kiro does not emit the suppressed steering file" =
            kiroFiles ? ".kiro/steering/active.md" && !(kiroFiles ? ".kiro/steering/disabled.md");
        }
    );

    module-disabled-empty-context-omits-output = mkTest "disabled-empty-context-omits-output" (
      let
        evaluate = context:
          evalDevenv {
            ai.copilot = {
              enable = true;
              github.context = context;
            };
          };
        path = ".github/copilot-instructions.md";
        check = context: expectedText: let
          result = evaluate (context // {enable = false;});
        in
          result.config.ai.copilot.github.context.text
          == expectedText
          && !((deliveredFiles result.config) ? ${path});
        text = "Disabled content remains inspectable.";
      in
        checkRows "disabled Copilot context" {
          "disabled empty context can be read without rejecting empty text or emitting a file" = check {} "";
          "disabled inline context retains its text but does not emit the enabled control's instruction file" =
            deliveredMarkdown (evaluate {inherit text;}) path == text && check {inherit text;} text;
        }
    );

    # A forced empty text winner disables the record even with a source present.
    module-text-source-force-empty-disables = mkTest "text-source-force-empty-disables" (
      let
        context =
          (evalHm {
            ai.context = {
              source = steeringDir + "/alpha.md";
              text = lib.mkForce "";
            };
          }).config.ai.context;
      in
        !context.enable && context.text == ""
    );

    module-single-context-source-does-not-trigger-ifd = mkTest "single-context-source-does-not-trigger-ifd" (
      let
        source = unbuildable "context-source-must-not-build";
        result = evalDevenv {
          ai.claude = {
            context = {inherit source;};
            enable = true;
          };
        };
        entry = (deliveredFiles result.config).${claudeContext};
        input = markdownInput result claudeContext;
      in
        # Delivered from the Markdown tree, which takes the source as it is:
        # the tree's derivation names it, and nothing reads its bytes.
        fromGeneratedTree claudeContext entry
        && !(entry ? text)
        && lib.attrNames input == ["source"]
        && toString input.source == toString source
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
        filesOf = result: deliveredFiles result.config;
        childrenOf = result: lib.filter (lib.hasPrefix ".agents/rules/") (lib.attrNames (filesOf result));
        child = ".agents/rules/guidance.md";
        withRoot = entry: {ai.codex.files."AGENTS.md" = entry;};
        override = config: evalDevenv (lib.recursiveUpdate base config);
        disabled = override (withRoot {enable = false;});
        replacement = withRoot {content.text = "Consumer root.";};
        # An index can be inspected without reading a discarded context source.
        lazy = override (lib.recursiveUpdate replacement {
          ai.context.source = unbuildable "tier-discarded-context-must-not-build";
        });
      in
        checkRows "shared AGENTS.md tier delivery" {
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
          "disabling the root does not leave its child behind" = childrenOf disabled == [];
          "replacing a tiered root omits its child without reading the discarded context source" =
            childrenOf lazy == [] && (filesOf lazy)."AGENTS.md".text == "Consumer root.";
          "the generated root links to the one read-only child and delivers its index instead of the rule body" = let
            rootText = deliveredMarkdown active "AGENTS.md";
            childText = deliveredMarkdown active child;
          in
            childrenOf active
            == [child]
            && (filesOf active).${child}.method == "ro"
            && hasLiteral "(${child})" rootText
            && hasLiteral "(../../docs/guidance/long-document-name-one.md)" childText
            && !(hasLiteral "RULE-BODY-MUST-NOT-BE-INLINED" (rootText + childText));
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
            kimchi.rules.inline.enable = false;
          };
        };
        agents = deliveredMarkdown result "AGENTS.md";
        files = deliveredFiles result.config;
        claude = deliveredMarkdown result ".claude/rules/scoped.md";
      in
        checkRows "shared AGENTS.md audiences and native routing" {
          "automatic fallback keeps its trigger, description, document, and both fallback runtimes together" = hasLiteral ("- **`automatic`**\n  - Trigger: `auto`\n  - Description: Use for deployment planning.\n"
            + "  - Read:\n    - [`docs/deploy.md`](docs/deploy.md)\n  - Audience: `codex`, `kimchi`\n")
          agents;
          "inline rule does not name the opted-out Kimchi runtime" =
            hasLiteral "<!-- rule: inline -->\n\nApply this rule only in: `codex`, `kiro`.\n\nInline guidance." agents;
          "manual fallback does not name the opted-out Codex runtime" =
            hasLiteral "- **`manual`**\n  - Trigger: `manual`\n  - Read:\n    - [`docs/ops.md`](docs/ops.md)\n  - Audience: `kimchi`\n" agents;
          "native Claude receives scoped guidance without fallback audience metadata" =
            hasLiteral "paths:\n  - \"src/**\"" claude && hasLiteral "Source guidance." claude && !(hasLiteral "Audience:" claude);
          "native Copilot receives the manual rule via its supported fileMatch fallback" =
            hasLiteral "applyTo: \"ops/**\"" (deliveredMarkdown result ".github/instructions/manual.instructions.md");
          "native Kiro still receives the scoped rule separately from the fallback" = files ? ".kiro/steering/scoped.md";
        }
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
          # Read the exact merge leaf, with both contributors present in the control.
          "one index entry cannot have two reference lists" =
            rejectsChange (ai: let
              result = shared ai;
            in {
              audience = result.audiences.scoped;
              entry = result.index.scoped;
            }) {
              valid = indexed ["source.md"];
              invalid = indexed ["other.md"];
              expected = {
                audience = ["codex" "kimchi"];
                entry = {
                  description = "";
                  inclusion = "fileMatch";
                  matcher = ["src/**"];
                  references = ["source.md"];
                };
              };
            };
          "one inline rule key cannot have two bodies" =
            rejectsChange (ai: let
              result = shared ai;
            in {
              audience = result.audiences.shared;
              body = result.rules.shared;
            }) {
              valid = inline "Shared guidance.";
              invalid = inline "Kiro-only guidance.";
              expected = {
                audience = ["codex" "kiro"];
                body = "Shared guidance.";
              };
            };
        }
    );

    # Kiro contributes a rule, not an empty context that conflicts with Codex's text.
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
      in
        deliveredMarkdown result "AGENTS.md"
        == "<!-- rule: kiro-only -->\n\nApply this rule only in: `kiro`.\n\nKiro rule.\n\nCodex-only context."
    );

    # A working runtime rulesDir would not catch a dropped root-to-Kiro handoff.
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

    # A working runtime skillsDir would not catch a dropped root-to-Claude handoff.
    module-top-level-skillsdir-fans-out-to-claude = mkTest "top-level-skillsdir-fans-out-to-claude" (
      let
        result = evalHm {
          ai = {
            claude.enable = true;
            skillsDir = ../../packages/claude-code/checks/fixtures/claude-skills;
          };
        };
        skillFiles = lib.filter (lib.hasPrefix ".claude/skills/") (lib.attrNames result.config.home.file);
      in
        skillFiles == [".claude/skills/skill-a/SKILL.md" ".claude/skills/skill-b/SKILL.md"]
    );

    # Reads what the tree delivers, never `home.packages`: installing the package
    # reads no rules, so a probe on it passes on laziness alone.
    module-runtime-rules-deliver-markdown = mkTest "runtime-rules-deliver-markdown" (
      let
        claude = rules: evalHm {ai.claude = rules // {enable = true;};};
        kimchi = rules: evalHm {ai.kimchi = rules // {enable = true;};};
        dir = {rulesDir = steeringDir;};
        inline = {rules.test.text = "Runtime guidance.";};
      in
        checkRows "runtime rules deliver Markdown" {
          "Claude emits only the Markdown members of its runtime rule directory, with their original bodies" = let
            result = claude dir;
            expected = {
              ".claude/rules/alpha.md" = "Alpha steering body.\n";
              ".claude/rules/beta.md" = "Beta steering body.\n";
              ".claude/rules/gamma.md" = "Gamma steering body.\n";
            };
            rulePaths = lib.filter (lib.hasPrefix ".claude/rules/") (lib.attrNames (deliveredFiles result.config));
          in
            rulePaths
            == lib.attrNames expected
            && lib.all (path: deliveredMarkdown result path == expected.${path}) rulePaths;
          "Kimchi aggregates only the Markdown members of its runtime rule directory, in key order" =
            deliveredMarkdown (kimchi dir) kimchiAgents
            == "<!-- rule: alpha -->\n\nAlpha steering body.\n\n\n<!-- rule: beta -->\n\nBeta steering body.\n\n\n<!-- rule: gamma -->\n\nGamma steering body.\n";
          "Kimchi delivers inline text from the runtime rule pool" =
            deliveredMarkdown (kimchi inline) kimchiAgents == "<!-- rule: test -->\n\nRuntime guidance.";
        }
    );
  };
}
