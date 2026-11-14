# Checks and the commit hook share pinned parsers; tests also use Hypothesis.
pkgs:
pkgs.python3.withPackages (ps: [
  ps.hypothesis
  ps.tree-sitter
  ps.tree-sitter-bash
  ps.tree-sitter-grammars.tree-sitter-nix
])
