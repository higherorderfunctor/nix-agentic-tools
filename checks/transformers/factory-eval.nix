# Factory contracts for this owner or shared primitive.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (import ../../lib/testing/factory-harness.nix {inherit lib pkgs harness;}) ai mkTest;
in {
  checks = {
    # ── Transformer shape tests ─────────────────────────────────────
    factory-transformer-claude-empty = mkTest "transformer-claude-empty" (
      ai.transformers.claude.render {text = "";} == ""
    );

    factory-transformer-claude-plain-text = mkTest "transformer-claude-plain-text" (
      ai.transformers.claude.render {text = "hello world";} == "hello world"
    );

    factory-transformer-claude-with-frontmatter = mkTest "transformer-claude-with-frontmatter" (
      let
        frontmatter = ai.transformers.claude.claudeTransformer.frontmatterData {
          description = "Test rule";
          paths = ["**/*.nix"];
          text = "body content";
        };
      in
        frontmatter.description == "Test rule"
    );

    factory-transformer-copilot-applyto = mkTest "transformer-copilot-applyto" (
      let
        frontmatter = ai.transformers.copilot.copilotTransformer.frontmatterData {
          description = "Nix rule";
          paths = [
            "**/*.nix"
            "**/*.toml"
          ];
          text = "body";
        };
      in
        frontmatter.applyTo == "**/*.nix,**/*.toml"
    );

    factory-transformer-kiro-always = mkTest "transformer-kiro-always" (
      let
        frontmatter = ai.transformers.kiro.kiroTransformer.frontmatterData {
          inclusion = "always";
          paths = ["**/*.nix"];
          text = "body";
        };
      in
        frontmatter.inclusion == "always" && !(frontmatter ? fileMatchPattern)
    );

    factory-transformer-kiro-auto = mkTest "transformer-kiro-auto" (
      let
        frontmatter = ai.transformers.kiro.kiroTransformer.frontmatterData {
          description = "Semantic Kiro guidance";
          inclusion = "auto";
          name = "semantic-guidance";
          paths = ["**/*.nix"];
          text = "body";
        };
      in
        frontmatter.description
        == "Semantic Kiro guidance"
        && frontmatter.inclusion == "auto"
        && frontmatter.name == "semantic-guidance"
        && !(frontmatter ? fileMatchPattern)
    );

    factory-transformer-kiro-fileMatch = mkTest "transformer-kiro-fileMatch" (
      let
        frontmatter = ai.transformers.kiro.kiroTransformer.frontmatterData {
          description = "Kiro rule";
          paths = ["**/*.nix"];
          text = "body";
        };
      in
        frontmatter.inclusion == "fileMatch" && frontmatter.fileMatchPattern == "**/*.nix"
    );

    # Several paths are a block sequence, one quoted glob per line. Prettier
    # reflows a long inline array into a multi-line flow array, which Kiro
    # loads on every turn instead of on a matching file.
    factory-transformer-kiro-fileMatch-several-paths = mkTest "transformer-kiro-fileMatch-several-paths" (
      ai.transformers.kiro.render {
        description = "Kiro rule";
        paths = [
          "**/*.nix"
          "lib/**"
        ];
        text = "body";
      }
      == "---\ndescription: \"Kiro rule\"\nfileMatchPattern:\n  - \"**/*.nix\"\n  - \"lib/**\"\ninclusion: \"fileMatch\"\n---\n\nbody"
    );

    factory-transformer-kiro-manual = mkTest "transformer-kiro-manual" (
      let
        frontmatter = ai.transformers.kiro.kiroTransformer.frontmatterData {
          inclusion = "manual";
          name = "on-demand";
          text = "body";
        };
      in
        frontmatter.inclusion
        == "manual"
        && frontmatter.name == "on-demand"
        && !(frontmatter ? fileMatchPattern)
    );

    factory-transformer-kiro-path-text = mkTest "transformer-kiro-path-text" (
      let
        args = {
          inclusion = "manual";
          name = "path-backed";
          text = ../../packages/kiro-cli/checks/fixtures/kiro-steering/alpha.md;
        };
        frontmatter = ai.transformers.kiro.kiroTransformer.frontmatterData args;
        out = ai.transformers.kiro.render args;
      in
        frontmatter.inclusion
        == "manual"
        && lib.hasInfix "Alpha steering body." out
    );

    factory-transformer-kiro-validates-required-fields = mkTest "transformer-kiro-validates-required-fields" (
      let
        succeeds = fragment:
          (builtins.tryEval (builtins.deepSeq (ai.transformers.kiro.render fragment) true)).success;
      in
        !(succeeds {
          description = "Missing name";
          inclusion = "auto";
          text = "body";
        })
        && !(succeeds {
          inclusion = "fileMatch";
          text = "body";
        })
    );

    factory-transformer-agentsmd-no-frontmatter = mkTest "transformer-agentsmd-no-frontmatter" (
      let
        out = ai.transformers.agentsmd.render {
          description = "ignored";
          paths = ["ignored"];
          text = "body only";
        };
      in
        out == "body only"
    );

    factory-transformer-agentsmd-tier-index = mkTest "transformer-agentsmd-tier-index" (
      let
        transformer = ai.transformers.agentsmd;
        scoped = {
          description = "";
          inclusion = "fileMatch";
          matcher = ["src/alpha/**" "src/*.nix" "src-other/**" "lib/shared.nix" "wild/*/**" "wild/*/leaf.nix"];
          references = map (n: "docs/guidance/long-document-name-${n}.md") ["one" "two" "three" "four"];
        };
        index = {
          alpha = scoped;
          automatic =
            scoped
            // {
              inclusion = "auto";
              description = "Deploy when relevant.";
            };
          beta = scoped // {matcher = ["src/**" "src/beta/**" "lib/shared.nix"];};
          manual = scoped // {inclusion = "manual";};
        };
        audiences = {
          alpha = ["codex"];
          automatic = ["codex"];
          beta = ["kimchi"];
          manual = ["kimchi"];
        };
        tier = transformer.tierIndex {
          filename = "nested/CUSTOM.md";
          inherit audiences index;
          hasOnDemandIndex = true;
        };
        childPath = "nested/CUSTOM.md.rules/${builtins.hashString "sha256" "docs/guidance"}.md";
        root = transformer.renderKeyed {
          inherit audiences;
          inherit (tier) index indexGroups;
          hasOnDemandIndex = true;
        };
        original = transformer.renderKeyed {
          inherit audiences index;
          hasOnDemandIndex = true;
        };
        # These fixtures emit plain Markdown links, one complete destination
        # per capture; resolve each against the file containing that link.
        resolvedLinks = filename: text:
          lib.sort builtins.lessThan (lib.unique (map
            (capture: toString (/. + "/workspace/${builtins.dirOf filename}/${builtins.head capture}"))
            (builtins.filter builtins.isList (builtins.split "[]][(]([^()]*)[)]" text))));
        sourceTargets = map (ref: "/workspace/${ref}") scoped.references;
        ungrouped = refs:
          transformer.tierIndex {
            filename = "AGENTS.md";
            audiences = {};
            hasOnDemandIndex = false;
            index = lib.genAttrs ["a" "b"] (_:
              scoped
              // {
                matcher = ["a"];
                references = refs;
              });
          };
      in
        lib.attrNames tier.children
        == [childPath]
        && lib.attrNames tier.index == ["automatic" "manual"]
        && (builtins.head tier.indexGroups).audiences == ["codex" "kimchi"]
        && (builtins.head tier.indexGroups).entry.matcher == ["lib/shared.nix" "src-other/**" "src/**" "wild/*/**" "wild/*/leaf.nix"]
        && resolvedLinks "nested/CUSTOM.md" root == lib.sort builtins.lessThan (sourceTargets ++ ["/workspace/${childPath}"])
        && resolvedLinks childPath tier.children.${childPath} == lib.sort builtins.lessThan sourceTargets
        && lib.hasInfix "  - Audience: `codex`" tier.children.${childPath}
        && lib.hasInfix "  - Audience: `kimchi`" tier.children.${childPath}
        && lib.hasInfix "`src/alpha/**`" tier.children.${childPath}
        && lib.hasInfix "`src/*.nix`" tier.children.${childPath}
        && lib.hasInfix "`src/beta/**`" tier.children.${childPath}
        && builtins.stringLength root < builtins.stringLength original
        && lib.all (refs: (ungrouped refs).children == {}) [
          ["a.md"]
          ["https://example.org/docs/one.md"]
          ["docs/a.md#anchor"]
          ["docs/a.md?query"]
          ["/absolute/a.md"]
          ["docs/a.md" "other/b.md"]
        ]
        && (transformer.tierIndex {
          filename = "AGENTS.md";
          audiences = {};
          hasOnDemandIndex = false;
          index.alpha = scoped;
        }).children
        == {}
    );

    factory-transformer-agentsmd-index-audience-deduplication = mkTest "transformer-agentsmd-index-audience-deduplication" (
      let
        index = lib.genAttrs ["alpha" "beta"] (_: {
          description = "";
          inclusion = "fileMatch";
          matcher = ["src/**"];
          references = ["guide.md"];
        });
        render = audiences: ai.transformers.agentsmd.renderKeyed {inherit audiences index;};
        uniform = render {
          alpha = ["codex" "kimchi"];
          beta = ["codex" "kimchi"];
        };
        mixed = render {
          alpha = ["codex"];
          beta = ["kimchi"];
        };
        private = render {};
      in
        lib.hasInfix "This fallback index applies only to: `codex`, `kimchi`.\n" uniform
        && !(lib.hasInfix "  - Audience:" uniform)
        && lib.hasInfix "If your runtime is not named, skip this index." uniform
        && lib.hasInfix "Runtimes with native rule injection" uniform
        && lib.hasInfix "  - Audience: `codex`\n" mixed
        && lib.hasInfix "  - Audience: `kimchi`\n" mixed
        && !(lib.hasInfix "This fallback index" private)
        && !(lib.hasInfix "Audience:" private)
    );

    factory-transformer-agentsmd-index-heading-uses-structure = mkTest "transformer-agentsmd-index-heading-uses-structure" (
      let
        index.example = {
          description = "Trigger: rendered text is not metadata";
          inclusion = "fileMatch";
          matcher = ["*.nix"];
          references = ["guide.md"];
        };
      in
        lib.hasPrefix "## Path-scoped rules\n" (ai.transformers.agentsmd.renderKeyed {inherit index;})
        && lib.hasPrefix "## Rule index\n" (ai.transformers.agentsmd.renderKeyed {
          hasOnDemandIndex = true;
          inherit index;
        })
    );
  };
}
