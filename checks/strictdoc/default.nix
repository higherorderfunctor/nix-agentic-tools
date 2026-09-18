{
  lib,
  pkgs,
  self,
  ...
}: let
  inherit (import ../../packages/strictdoc-grammar/checks/helpers.nix {inherit lib pkgs;}) sdocTsEnv strictdocGrammarExtract;
in {
  imports = [./module-eval.nix];
  checks = {
    daemon-only-source = import ./daemon-only-source.nix {inherit pkgs self;};
    interpreter-launchers = import ./interpreter-launchers.nix {inherit pkgs self;};
    strictdoc-board-grammar-groups = import ./strictdoc-board-grammar-groups.nix {inherit pkgs self;};
    strictdoc-commentary-check = import ./strictdoc-commentary-check.nix {inherit pkgs sdocTsEnv self;};
    strictdoc-cycle-check = import ./strictdoc-cycle-check.nix {inherit pkgs sdocTsEnv self;};
    strictdoc-element-check = import ./strictdoc-element-check.nix {inherit pkgs self strictdocGrammarExtract;};
    strictdoc-file-check = import ./strictdoc-file-check.nix {inherit pkgs sdocTsEnv self;};
    strictdoc-fp-check = import ./strictdoc-fp-check.nix {inherit pkgs sdocTsEnv self;};
    strictdoc-grammar-corpus = import ./strictdoc-grammar-corpus.nix {inherit lib pkgs self;};
    strictdoc-grammar-model-equal = import ./strictdoc-grammar-model-equal.nix {inherit lib pkgs self strictdocGrammarExtract;};
    strictdoc-nix-extractor = import ./strictdoc-nix-extractor.nix {inherit pkgs self strictdocGrammarExtract;};
    strictdoc-semantics = import ./strictdoc-semantics.nix {inherit pkgs self strictdocGrammarExtract;};
  };
}
