_context: {
  claims = [["ai" "devTools" "added"]];
  overlay = _final: _prev: {
    ai.devTools.added = "sparse";
  };
}
