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
  # per capture; resolve each against the file containing that link. Preserve
  # duplicates so two links to one document cannot stand in for one link each.
  resolvedLinks = filename: text:
    lib.sort builtins.lessThan (map
      (capture: toString (/. + "/workspace/${builtins.dirOf filename}/${builtins.head capture}"))
      (builtins.filter builtins.isList (builtins.split "[]][(]([^()]*)[)]" text)));

  # Read each rule's section rather than matching across adjacent rules.
  ruleSection = text: name:
    lib.findFirst (lib.hasPrefix "`${name}`**\n") "" (builtins.tail (lib.splitString "\n- **" text));
  ruleLines = prefix: section: lib.filter (lib.hasPrefix prefix) (lib.splitString "\n" section);
in {
  checks = {
    # ── Transformer shape tests ─────────────────────────────────────
    factory-transformer-frontmatter = mkTest "transformer-frontmatter" (
      let
        scoped = {
          description = "Nix rule";
          paths = ["**/*.nix" "**/*.toml"];
          text = "body";
        };
      in
        checkRows "transformer frontmatter" {
          "AGENTS.md discards both description and paths" = ai.transformers.agentsmd.render scoped == "body";
          "Claude does not manufacture frontmatter or a newline for empty text" = ai.transformers.claude.render {text = "";} == "";
          "Claude retains the explicit description alongside the path list" =
            ai.transformers.claude.render scoped
            == "---\ndescription: \"Nix rule\"\npaths:\n  - \"**/*.nix\"\n  - \"**/*.toml\"\n---\n\nbody";
          "Copilot joins both globs in order and omits the description" =
            ai.transformers.copilot.render scoped == "---\napplyTo: \"**/*.nix,**/*.toml\"\n---\n\nbody";
        }
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
          "always ignores paths and an unknown inclusion mode is rejected" = rejectsRender {
            expected = alwaysOutput;
            invalid = always // {inclusion = "unknown";};
            valid = always;
          };
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
          "manual keeps its name and ignores paths" =
            render (always
              // {
                inclusion = "manual";
                name = "on-demand";
              })
            == "---\ninclusion: \"manual\"\nname: \"on-demand\"\n---\n\nbody";
          # The direct renderer reads a path itself; runtime rule rendering
          # already converts sources to strings before invoking the transformer.
          "path body is read verbatim and one glob implies fileMatch with a scalar pattern" =
            render (scoped // {text = ../../packages/kiro-cli/checks/fixtures/kiro-steering/alpha.md;})
            == "---\ndescription: \"Kiro rule\"\nfileMatchPattern: \"**/*.nix\"\ninclusion: \"fileMatch\"\n---\n\nAlpha steering body.\n";
        }
    );

    # ── AGENTS.md index tests ─────────────────────────────────────────
    factory-transformer-agentsmd-tier-index = mkTest "transformer-agentsmd-tier-index" (
      let
        transformer = ai.transformers.agentsmd;
        scoped = {
          description = "";
          inclusion = "fileMatch";
          # Non-alphabetical order distinguishes the child's original globs
          # from the reduced, sorted matcher list in the root.
          matcher = ["src/alpha/**" "src/*.nix" "src-other/**" "lib/shared.nix" "wild/*/**" "wild/*/leaf.nix"];
          references = map (n: "docs/guidance/long-document-name-${n}.md") ["one" "two" "three" "four"];
        };
        index = {
          alpha = scoped;
          automatic =
            scoped
            // {
              description = "Deploy when relevant.";
              inclusion = "auto";
              references = ["docs/guidance/deploy.md"];
            };
          beta = scoped // {matcher = ["src/**" "src/beta/**" "lib/shared.nix"];};
          manual =
            scoped
            // {
              inclusion = "manual";
              references = ["docs/guidance/operations.md"];
            };
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
        sourceTargets = map (ref: "/workspace/${ref}") scoped.references;
        child = tier.children.${childPath} or "";
        childRule = name: expectedAudience: expectedGlobs: let
          section = ruleSection child name;
        in
          ruleLines "  - Audience:" section
          == ["  - Audience: `${expectedAudience}`"]
          && ruleLines "    - `" section == map (glob: "    - `${glob}`") expectedGlobs
          && resolvedLinks childPath section == lib.sort builtins.lessThan sourceTargets;
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
        # A long key widens the byte savings from grouping a single rule, so
        # the minimum group size still matters if the fixture uses fewer links.
        longRuleName = lib.concatStrings (lib.replicate 100 "long-rule-");
      in
        checkRows "AGENTS.md tier index" {
          "absolute links stay in the root" = staysInDefaultRoot (longLinks "/");
          "child keeps alpha's exact audience, globs and resolved links" = childRule "alpha" "codex" ["src/alpha/**" "src/*.nix" "src-other/**" "lib/shared.nix" "wild/*/**" "wild/*/leaf.nix"];
          "child keeps beta's exact audience, globs and resolved links" = childRule "beta" "kimchi" ["src/**" "src/beta/**" "lib/shared.nix"];
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
          "query links stay in the root" = staysInDefaultRoot (scoped.references ++ ["docs/guidance/a.md?query"]);
          "remote links stay in the root" = staysInDefaultRoot (longLinks "https://example.org/");
          "root resolves its child and both on-demand documents from the nested target" =
            resolvedLinks "nested/CUSTOM.md" root
            == ["/workspace/docs/guidance/deploy.md" "/workspace/docs/guidance/operations.md" "/workspace/${childPath}"];
          "single rule stays in the root even when grouping would save bytes" = staysInRoot "AGENTS.md" {${longRuleName} = scoped;};
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
        ruleNames = ["alpha" "beta"];
        index = lib.listToAttrs (lib.concatMap (parent:
          map (name: {
            name = "${parent}-${name}";
            value = {
              description = "";
              inclusion = "fileMatch";
              matcher = ["src/${name}/**"];
              references = sourceRefs parent;
            };
          })
          ruleNames)
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
          # The child link prefix depends on depth, not the sibling name.
          # Keep one owner docs path and the guidance paths that pin both
          # the depth and literal index.md source component in each namespace.
          linkParents =
            lib.subtractLists (
              ["other/guidance" "other/index.md" "packages/kimchi/docs"]
              ++ lib.optional (target == "CUSTOM.md") "dev/fragments/ai-module"
            )
            parents;
        in
          checkRows target ({
              "child paths match exactly" = lib.attrNames tier.children == lib.sort builtins.lessThan (map childPath parents);
            }
            // lib.optionalAttrs (target == "nested/AGENTS.md") {
              "root links resolve to every child" = resolvedLinks target root == lib.sort builtins.lessThan (map (parent: "/workspace/${childPath parent}") parents);
            }
            // lib.listToAttrs (map (parent: let
              child = tier.children.${childPath parent} or "";
              expected = lib.sort builtins.lessThan (map (ref: "/workspace/${ref}") (sourceRefs parent));
            in
              lib.nameValuePair "both rules in the child for ${parent} link to their source documents" (
                lib.all (name: resolvedLinks (childPath parent) (ruleSection child "${parent}-${name}") == expected) ruleNames
              ))
            linkParents));
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
      in
        checkRows "AGENTS.md index audiences" {
          "uniform audience is declared globally, not per rule" =
            lib.hasInfix "This fallback index applies only to: `codex`, `kimchi`.\n" uniform
            && !(lib.hasInfix "  - Audience:" uniform);
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
          "on-demand metadata makes the generic heading lead the same index" = lib.hasPrefix "## Rule index\n" (ai.transformers.agentsmd.renderKeyed {
            hasOnDemandIndex = true;
            inherit index;
          });
        }
    );
  };
}
