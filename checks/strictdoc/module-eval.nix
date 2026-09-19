# Repository grammar rendering and Semble's custom-parser integration.
{
  lib,
  pkgs,
  harness,
  ...
}: let
  inherit (harness) evalDevenv mkTest;
  strictdocGrammarLib = import ../../packages/strictdoc-grammar/lib/grammar.nix {inherit lib;};
in {
  checks = {
    module-strictdoc-grammars-render-committed-file = mkTest "strictdoc-grammars-render-committed-file" (
      let
        cfg =
          (evalDevenv {
            ai.strictdoc.grammars.repo = {
              target = "docs/sdoc/grammar.sgra";
              elements =
                import ../../packages/strictdoc-grammar/values.nix
                {inherit (strictdocGrammarLib) dsl;};
            };
          })
        .config
        .ai
        .strictdoc
        .grammars
        .repo;
      in
        cfg.target
        == "docs/sdoc/grammar.sgra"
        && cfg.rendered == builtins.readFile ../../docs/sdoc/grammar.sgra
    );

    # SLICE-SDOC-IN-SEMBLE (docs/plans/strictdoc-tooling/slice-sdoc-in-semble.sdoc):
    # the custom (non-nixpkgs) grammar load path, exercised through the exact same
    # production entry point as the Semble owner's extra-grammar check, and a real
    # .sdoc sample rather than a synthetic snippet.
    module-semble-strictdoc-grammar-load = let
      customizePackage = import ../../packages/semble/lib/withGrammars.nix {inherit lib pkgs;};
      pathMappings = [
        {
          content = "docs";
          language = "strictdoc";
          patterns = ["*.sdoc" "*.sgra"];
        }
      ];
      sembleWithGrammars =
        customizePackage pkgs.ai.semble [pkgs.ai.generic.tree-sitter-strictdoc]
        pathMappings;
      # pkgs.writeText, not a heredoc: interpolating a multi-line string as its
      # own heredoc line double-counts the trailing newline (the value's own
      # "\n" plus the outer string's line-end "\n"), leaving a blank line at
      # EOF the grammar does not tolerate — measured directly against this
      # fixture.
      sampleDoc = pkgs.writeText "strictdoc-grammar-sample.sdoc" ''
        [DOCUMENT]
        TITLE: Sample

        [GRAMMAR]
        IMPORT_FROM_FILE: @repo

        [MECHANISM]
        UID: MECH-SAMPLE
        TITLE: Sample mechanism
        AUTHORED_BY: llm
        STATEMENT: >>>
        A minimal MECHANISM node, parsed to prove the strictdoc grammar loads
        through Semble's real extra-grammars entry point.
        <<<
      '';
    in
      assert sembleWithGrammars.passthru.updateFlakeInput == "llm-agents";
        pkgs.runCommand "module-test-semble-strictdoc-grammar-load" {} ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :

          ${pkgs.coreutils}/bin/mkdir -p repo/docs
          ${pkgs.coreutils}/bin/cp ${sampleDoc} repo/docs/sample.sdoc
          ${pkgs.coreutils}/bin/head -n 3 ${sembleWithGrammars}/bin/.semble-wrapped > test-strictdoc-grammar.py
          ${pkgs.coreutils}/bin/cat >> test-strictdoc-grammar.py <<'PY'
          from pathlib import Path

          from semble.chunking.core import _cached_get_parser
          from semble.index.files import detect_language

          root = Path("repo").resolve()
          sample = root / "docs" / "sample.sdoc"
          assert detect_language(sample, root) == "strictdoc"

          parser = _cached_get_parser("strictdoc")
          assert parser is not None
          tree = parser.parse(sample.read_bytes())

          def error_count(node):
              count = 1 if (node.type in ("ERROR", "MISSING") or node.is_error) else 0
              for child in node.children:
                  count += error_count(child)
              return count

          assert error_count(tree.root_node) == 0, tree.root_node.type
          PY
          ${pkgs.coreutils}/bin/chmod +x test-strictdoc-grammar.py
          ./test-strictdoc-grammar.py
          ${pkgs.coreutils}/bin/touch "$out"
        '';
  };
}
