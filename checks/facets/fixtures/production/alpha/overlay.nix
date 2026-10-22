_context: {
  claims = [
    ["ai" "alpha"]
    ["ai" "devTools" "alpha-note"]
  ];
  overlay = _final: prev: {
    ai = {
      alpha = "${prev.ai.seed}:alpha";
      devTools.alpha-note = "${prev.ai.devTools.seed}:alpha-note";
    };
  };
}
