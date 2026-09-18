{
  inputs,
  lib,
  pkgs,
  ...
}: let
  grammar = inputs.library.lib.ai.strictdocGrammar {inherit lib;};
in {
  imports = [inputs.library.devenvModules.nix-agentic-tools];

  ai.strictdoc = {
    enable = true;
    package = inputs.library.packages.${pkgs.stdenv.hostPlatform.system}.strictdoc;
    grammars.fixture = {
      elements = import ./grammar.nix {inherit (grammar) dsl;};
      target = "grammar.sgra";
    };
  };
}
