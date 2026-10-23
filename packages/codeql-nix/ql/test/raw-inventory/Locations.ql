import nix.internal.generated.Ast

from Nix::Token token, string file, int sl, int sc, int el, int ec
where
  token.getValue() = ["41", "97"] and
  file = token.getLocation().getFile().getRelativePath() and
  token.getLocation().getFile().getAbsolutePath().matches("%/" + file) and
  sl = token.getLocation().getStartLine() and
  sc = token.getLocation().getStartColumn() and
  el = token.getLocation().getEndLine() and
  ec = token.getLocation().getEndColumn()
select file, token.getValue(), sl, sc, el, ec
