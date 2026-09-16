{
  libPath ? /nix/store/j2r11kxv91yl5xqppy3vy84klwxjbz1i-source/lib,
  grammarPath ? ../../../../../packages/strictdoc-grammar/lib,
}: let
  lib = import libPath;
  grammar = import (grammarPath + "/grammar.nix") {inherit lib;};
  dsl = import ./dsl.nix {inherit lib grammar;};
  model = import ../recommended.nix {
    inherit grammar;
    inherit (dsl) schema constraint;
  };
in
  builtins.deepSeq model.normalized {
    inherit (model) normalized rendered;
  }
