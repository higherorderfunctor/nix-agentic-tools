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

    factory-transformer-agentsmd-index-heading-uses-structure = mkTest "transformer-agentsmd-index-heading-uses-structure" (
      let
        index = {example = "  - Trigger: rendered text is not metadata\n";};
      in
        lib.hasPrefix "## Path-scoped rules\n" (ai.transformers.agentsmd.renderKeyed {inherit index;})
        && lib.hasPrefix "## Rule index\n" (ai.transformers.agentsmd.renderKeyed {
          hasOnDemandIndex = true;
          inherit index;
        })
    );
  };
}
