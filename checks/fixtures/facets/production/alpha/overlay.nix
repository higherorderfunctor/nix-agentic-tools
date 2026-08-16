_context: {
  claims = [["ai" "alpha"]];
  overlay = _final: prev: {
    ai = prev.ai // {alpha = "${prev.ai.seed}:alpha";};
  };
}
