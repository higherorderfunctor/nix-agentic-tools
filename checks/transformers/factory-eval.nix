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
        out = ai.transformers.claude.render {
          description = "Test rule";
          paths = ["**/*.nix"];
          text = "body content";
        };
      in
        lib.hasPrefix "---\n" out && lib.hasInfix "description: Test rule" out
    );

    factory-transformer-copilot-applyto = mkTest "transformer-copilot-applyto" (
      let
        out = ai.transformers.copilot.render {
          description = "Nix rule";
          paths = [
            "**/*.nix"
            "**/*.toml"
          ];
          text = "body";
        };
      in
        out
        == "---\napplyTo: \"**/*.nix,**/*.toml\"\n---\n\nbody"
    );

    factory-transformer-kiro-always = mkTest "transformer-kiro-always" (
      let
        out = ai.transformers.kiro.render {
          inclusion = "always";
          paths = ["**/*.nix"];
          text = "body";
        };
      in
        lib.hasInfix "inclusion: always" out && !(lib.hasInfix "fileMatchPattern:" out)
    );

    factory-transformer-kiro-auto = mkTest "transformer-kiro-auto" (
      let
        out = ai.transformers.kiro.render {
          description = "Semantic Kiro guidance";
          inclusion = "auto";
          name = "semantic-guidance";
          paths = ["**/*.nix"];
          text = "body";
        };
      in
        lib.hasInfix "description: Semantic Kiro guidance" out
        && lib.hasInfix "inclusion: auto" out
        && lib.hasInfix "name: semantic-guidance" out
        && !(lib.hasInfix "fileMatchPattern:" out)
    );

    factory-transformer-kiro-fileMatch = mkTest "transformer-kiro-fileMatch" (
      let
        out = ai.transformers.kiro.render {
          description = "Kiro rule";
          paths = ["**/*.nix"];
          text = "body";
        };
      in
        lib.hasInfix "inclusion: fileMatch" out && lib.hasInfix "fileMatchPattern:" out
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
      == "---\ndescription: Kiro rule\nfileMatchPattern:\n  - \"**/*.nix\"\n  - \"lib/**\"\ninclusion: fileMatch\n---\n\nbody"
    );

    factory-transformer-kiro-manual = mkTest "transformer-kiro-manual" (
      let
        out = ai.transformers.kiro.render {
          inclusion = "manual";
          name = "on-demand";
          text = "body";
        };
      in
        lib.hasInfix "inclusion: manual" out
        && lib.hasInfix "name: on-demand" out
        && !(lib.hasInfix "fileMatchPattern:" out)
    );

    factory-transformer-kiro-path-text = mkTest "transformer-kiro-path-text" (
      let
        out = ai.transformers.kiro.render {
          inclusion = "manual";
          name = "path-backed";
          text = ../../packages/kiro-cli/checks/fixtures/kiro-steering/alpha.md;
        };
      in
        lib.hasInfix "inclusion: manual" out
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
  };
}
