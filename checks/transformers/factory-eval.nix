# Factory contracts for this owner or shared primitive.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (import ../../lib/testing/factory-harness.nix {inherit lib pkgs harness;}) ai mkTest;
  inherit (harness) checkRows rejectsChange;

  # These fixtures emit plain Markdown links, one complete destination
  # per capture; resolve each against the file containing that link.
  resolvedLinks = filename: text:
    lib.sort builtins.lessThan (lib.unique (map
      (capture: toString (/. + "/workspace/${builtins.dirOf filename}/${builtins.head capture}"))
      (builtins.filter builtins.isList (builtins.split "[]][(]([^()]*)[)]" text))));

  # Split only at top-level rule bullets, not indented glob or link bullets.
  hasRule = text: name: markers:
    lib.any (rule: lib.hasPrefix "`${name}`**\n" rule && lib.all (marker: lib.hasInfix marker rule) markers)
    (builtins.tail (lib.splitString "\n- **" text));
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

    factory-transformer-kiro-frontmatter = mkTest "transformer-kiro-frontmatter" (
      let
        inherit (ai.transformers.kiro) render;
        always = {
          inclusion = "always";
          paths = ["**/*.nix"];
          text = "body";
        };
        automatic =
          always
          // {
            description = "Semantic Kiro guidance";
            inclusion = "auto";
            name = "semantic-guidance";
          };
        scoped = {
          description = "Kiro rule";
          inherit (always) paths;
          text = "body";
        };
        explicit = scoped // {inclusion = "fileMatch";};
        alwaysOutput = "---\ninclusion: \"always\"\n---\n\nbody";
        autoOutput = "---\ndescription: \"Semantic Kiro guidance\"\ninclusion: \"auto\"\nname: \"semantic-guidance\"\n---\n\nbody";
        scopedOutput = "---\ndescription: \"Kiro rule\"\nfileMatchPattern: \"**/*.nix\"\ninclusion: \"fileMatch\"\n---\n\nbody";
        # Keep the body inline and the remaining YAML fields valid so only
        # the tested inclusion validation can reject each changed input.
        rejectsRender = rejectsChange render;
      in
        checkRows "Kiro frontmatter" {
          "always ignores paths" = render always == alwaysOutput;
          "auto requires a non-empty name" = rejectsRender {
            expected = autoOutput;
            invalid = builtins.removeAttrs automatic ["name"];
            valid = automatic;
          };
          "fileMatch requires paths" = rejectsRender {
            expected = scopedOutput;
            invalid = builtins.removeAttrs explicit ["paths"];
            valid = explicit;
          };
          "manual emits name but no path pattern" =
            render (always
              // {
                inclusion = "manual";
                name = "on-demand";
              })
            == "---\ninclusion: \"manual\"\nname: \"on-demand\"\n---\n\nbody";
          "path list with one glob implies fileMatch and emits a scalar" = render scoped == scopedOutput;
          "unknown inclusion mode is rejected" = rejectsRender {
            expected = alwaysOutput;
            invalid = always // {inclusion = "unknown";};
            valid = always;
          };
        }
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

    factory-transformer-kiro-path-text = mkTest "transformer-kiro-path-text" (
      ai.transformers.kiro.render {
        inclusion = "manual";
        name = "path-backed";
        text = ../../packages/kiro-cli/checks/fixtures/kiro-steering/alpha.md;
      }
      == "---\ninclusion: \"manual\"\nname: \"path-backed\"\n---\n\nAlpha steering body.\n"
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
        childPath = "nested/.agents/rules/targets/CUSTOM_dot_md/guidance.md";
        root = transformer.renderKeyed {
          inherit audiences;
          inherit (tier) index indexGroups;
          hasOnDemandIndex = true;
        };
        original = transformer.renderKeyed {
          inherit audiences index;
          hasOnDemandIndex = true;
        };
        sourceTargets = map (ref: "/workspace/${ref}") scoped.references;
        child = tier.children.${childPath} or "";
        tiersWithoutAudiences = filename: entries:
          transformer.tierIndex {
            inherit filename;
            audiences = {};
            hasOnDemandIndex = false;
            index = entries;
          };
        paired = refs: lib.genAttrs ["a" "b"] (_: scoped // {references = refs;});
        staysInRoot = filename: entries: let
          ungrouped = tiersWithoutAudiences filename entries;
        in
          ungrouped.children == {} && ungrouped.indexGroups == [] && ungrouped.index == entries;
        # Use enough links that the pair would save space if grouped; a short
        # list could stay in the root even if the link restriction disappeared.
        longLinks = prefix: map (ref: "${prefix}${ref}") scoped.references;
        staysInDefaultRoot = refs: staysInRoot "AGENTS.md" (paired refs);
      in
        checkRows "AGENTS.md tier index" {
          "absolute links stay in the root" = staysInDefaultRoot (longLinks "/");
          "child links resolve to the source documents" = resolvedLinks childPath child == lib.sort builtins.lessThan sourceTargets;
          "child retains alpha's audience and original globs" = hasRule child "alpha" [
            "  - Audience: `codex`\n"
            "`src/*.nix`"
            "`src/alpha/**`"
          ];
          "child retains beta's audience and original globs" = hasRule child "beta" [
            "  - Audience: `kimchi`\n"
            "`src/beta/**`"
          ];
          "documents from different directories stay in the root" = staysInDefaultRoot (scoped.references ++ ["other/b.md"]);
          "fragment links stay in the root" = staysInDefaultRoot (scoped.references ++ ["docs/guidance/a.md#anchor"]);
          "group uses the union of audiences and drops only covered globs" =
            map (group: {
              inherit (group) audiences;
              inherit (group.entry) matcher;
            })
            tier.indexGroups
            == [
              {
                audiences = ["codex" "kimchi"];
                matcher = ["lib/shared.nix" "src-other/**" "src/**" "wild/*/**" "wild/*/leaf.nix"];
              }
            ];
          "long child link would increase the root size" = staysInRoot "${lib.concatStrings (lib.replicate 100 "long-custom-target-")}.md" (paired scoped.references);
          "on-demand rules stay in the root" = lib.attrNames tier.index == ["automatic" "manual"];
          "one child is emitted in the custom target namespace" = lib.attrNames tier.children == [childPath];
          "query links stay in the root" = staysInDefaultRoot (scoped.references ++ ["docs/guidance/a.md?query"]);
          "relative links can move into a child" = lib.attrNames (tiersWithoutAudiences "AGENTS.md" (paired scoped.references)).children == [".agents/rules/guidance.md"];
          "remote links stay in the root" = staysInDefaultRoot (longLinks "https://example.org/");
          "root links resolve to the child and on-demand documents" = resolvedLinks "nested/CUSTOM.md" root == lib.sort builtins.lessThan (sourceTargets ++ ["/workspace/${childPath}"]);
          "single rule stays in the root" = staysInRoot "AGENTS.md" {alpha = scoped;};
          "tiering makes the root smaller" = builtins.stringLength root < builtins.stringLength original;
        }
    );

    factory-transformer-agentsmd-tier-readable-paths = mkTest "transformer-agentsmd-tier-readable-paths" (
      let
        transformer = ai.transformers.agentsmd;
        childNames = {
          "dev/fragments/ai-module" = "ai-module.md";
          "docs/guidance" = "by-path/docs/guidance/index.md";
          "docs/guidance/index.md" = "by-path/docs/guidance/index_dot_md/index.md";
          "other/guidance" = "by-path/other/guidance/index.md";
          "other/index.md" = "by-path/other/index_dot_md/index.md";
          "packages/kimchi/docs" = "kimchi.md";
          "packages/kiro-cli/docs" = "kiro-cli.md";
        };
        sourceRefs = parent: map (n: "${parent}/long-document-name-${n}.md") ["one" "two" "three" "four" "five" "six"];
        parents = lib.attrNames childNames;
        index = lib.listToAttrs (lib.concatMap (parent:
          map (name: {
            name = "${parent}-${name}";
            value = {
              description = "";
              inclusion = "fileMatch";
              matcher = ["src/${name}/**"];
              references = sourceRefs parent;
            };
          }) ["alpha" "beta"])
        parents);
        targets = {
          "AGENTS.md" = ".agents/rules/";
          "CUSTOM.md" = ".agents/rules/targets/CUSTOM_dot_md/";
          "nested/AGENTS.md" = "nested/.agents/rules/";
          "nested/CUSTOM.md" = "nested/.agents/rules/targets/CUSTOM_dot_md/";
        };
        # Each child resolves its links to the original workspace documents,
        # regardless of target namespace or collision-disambiguation depth.
        checkTarget = target: prefix: let
          tier = transformer.tierIndex {
            audiences = {};
            filename = target;
            hasOnDemandIndex = false;
            inherit index;
          };
          childPath = parent: prefix + childNames.${parent};
          root = transformer.renderKeyed {inherit (tier) index indexGroups;};
        in
          checkRows target ({
              "child paths match exactly" = lib.attrNames tier.children == lib.sort builtins.lessThan (map childPath parents);
              "root links resolve to every child" = resolvedLinks target root == lib.sort builtins.lessThan (map (parent: "/workspace/${childPath parent}") parents);
            }
            // lib.mapAttrs' (parent: _:
              lib.nameValuePair "child for ${parent} links to its source documents" (
                resolvedLinks (childPath parent) (tier.children.${childPath parent} or "") == lib.sort builtins.lessThan (map (ref: "/workspace/${ref}") (sourceRefs parent))
              ))
            childNames);
      in
        checkRows "AGENTS.md tier namespaces" (lib.mapAttrs checkTarget targets)
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
        checkRows "AGENTS.md index audiences" {
          "mixed audiences are attributed to their own rule" =
            hasRule mixed "alpha" ["  - Audience: `codex`\n"]
            && hasRule mixed "beta" ["  - Audience: `kimchi`\n"];
          "uniform audience is declared globally, not per rule" =
            lib.hasInfix "This fallback index applies only to: `codex`, `kimchi`.\n" uniform
            && !(lib.hasInfix "  - Audience:" uniform)
            && lib.hasInfix "If your runtime is not named, skip this index." uniform
            && lib.hasInfix "Runtimes with native rule injection" uniform;
          "untagged rules render without fallback guidance" =
            hasRule private "alpha" ["[`guide.md`](guide.md)"]
            && hasRule private "beta" ["[`guide.md`](guide.md)"]
            && !(lib.hasInfix "This fallback index" private)
            && !(lib.hasInfix "Audience:" private);
        }
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
        checkRows "AGENTS.md index headings" {
          "description alone does not make a rule on demand" = lib.hasPrefix "## Path-scoped rules\n" (ai.transformers.agentsmd.renderKeyed {inherit index;});
          "on-demand index uses the generic heading" = lib.hasPrefix "## Rule index\n" (ai.transformers.agentsmd.renderKeyed {
            hasOnDemandIndex = true;
            inherit index;
          });
        }
    );
  };
}
