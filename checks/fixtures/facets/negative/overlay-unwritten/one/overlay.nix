_context: {
  claims = [["ai" "shared"]];
  overlay = _final: prev: {inherit (prev) ai;};
}
