import Ast


private predicate located(
  Nix::Token token, string file, string text, int sl, int sc, int el, int ec
) {
  file = token.getLocation().getFile().getRelativePath() and
  text = token.getValue() and
  sl = token.getLocation().getStartLine() and
  sc = token.getLocation().getStartColumn() and
  el = token.getLocation().getEndLine() and
  ec = token.getLocation().getEndColumn()
}

predicate raw(string file, string text, int sl, int sc, int el, int ec) {
  exists(Nix::Token token | located(token, file, text, sl, sc, el, ec))
}

predicate joined(string file, string target, string text, int sl, int sc, int el, int ec) {
  exists(Nix::Token token |
    nx_bootstrap_targets(_, token.getLocation().getFile(), target, text) and
    located(token, file, text, sl, sc, el, ec)
  )
}
