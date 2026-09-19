{
  lib,
  pkgs,
  ...
}: let
  inherit (import ./checks/helpers.nix {inherit lib pkgs;}) strictdocGrammarExtract;
in {
  imports = [./checks/module-eval.nix];
  checks = {
    strictdoc-grammar-foreign-roundtrip = import ./checks/strictdoc-grammar-foreign-roundtrip.nix {inherit lib pkgs strictdocGrammarExtract;};
    strictdoc-grammar-negative-fixtures = import ./checks/strictdoc-grammar-negative-fixtures.nix {inherit lib pkgs strictdocGrammarExtract;};
    strictdoc-grammar-surface-current = import ./checks/strictdoc-grammar-surface-current.nix {inherit pkgs strictdocGrammarExtract;};
    strictdoc-grammar-surface-live = import ./checks/strictdoc-grammar-surface-live.nix {inherit lib pkgs;};
  };
}
