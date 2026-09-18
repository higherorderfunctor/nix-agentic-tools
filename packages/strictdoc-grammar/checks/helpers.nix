{
  lib,
  pkgs,
}: {
  sdocTsEnv = (import ../lib/tsGrammars.nix {inherit lib pkgs;}).env;
  strictdocGrammarExtract = import ../lib/mkExtract.nix {
    inherit lib pkgs;
    inherit (pkgs.ai.devTools) strictdoc;
  };
}
