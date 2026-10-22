_context: {
  claims = [["ai" "devTools" "added"]];
  overlay = _final: prev: {
    ai = prev.ai // {devTools = prev.ai.devTools // {added = "re-emitted";};};
  };
}
