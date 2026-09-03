# cspell:ignore dlopened dlopens
# The tree-sitter grammars dev/scripts/sdoc_extractors/ dlopens, and the
# environment variables that deliver them.
#
# ONE ROW PER LANGUAGE, and the row is the whole convention: the attribute name
# becomes the env var `SDOC_TS_<NAME>_PARSER` and the C entry point
# `tree_sitter_<name>`, both of which dev/scripts/sdoc_extractors/<name>.py
# spells out again on the Python side.
#
# ── Why this is its own file rather than a `let` in mkExtract.nix ───────────
#
# It has TWO consumers that must not drift, and they are not each other:
#
# * ./mkExtract.nix bakes the paths onto the strictdoc-grammar-extract wrapper
#   with `--set-default`, which is how every scribe program and every check
#   that runs that interpreter sees them.
#
# * devenv.nix puts the SAME paths in the dev shell's environment, because a
#   hand-run `strictdoc export` is NOT wrapped. That stopped being optional
#   when strictdoc_config.py turned REQUIREMENT_TO_SOURCE_TRACEABILITY on: a
#   shell without these variables now fails every export with "no tree-sitter
#   parser for symbol", rather than merely reading no source items.
#
# `--set-default` on the wrapper and a plain `env` entry here compose the right
# way round: the shell's value wins, which is the documented override path for
# a developer pointing at a locally built grammar.
{
  lib,
  pkgs,
}: let
  # Language name -> the grammar derivation whose `$out/parser` is dlopened.
  grammars = {
    bash = pkgs.tree-sitter-grammars.tree-sitter-bash;
    nix = pkgs.tree-sitter-grammars.tree-sitter-nix;
  };

  envName = name: "SDOC_TS_${lib.toUpper name}_PARSER";
in {
  inherit envName grammars;

  # The C entry point the ctypes loader asks the shared object for.
  symbolName = name: "tree_sitter_${name}";

  # `{ SDOC_TS_BASH_PARSER = "<store>/parser"; ... }` -- ready for a devenv
  # `env` block or anything else that wants plain name/value pairs.
  env =
    lib.mapAttrs'
    (name: grammar: lib.nameValuePair (envName name) "${grammar}/parser")
    grammars;
}
