_context: {
  claims = ["ai.shared"];
  overlay = _final: prev: {
    ai = prev.ai // {shared = "one";};
  };
}
