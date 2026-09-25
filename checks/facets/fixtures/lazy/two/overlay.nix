# A later ordinary overlay in the same namespace as owner `one`'s function
# leaf. Its claim check must not compare that leaf.
_context: {
  claims = [["ai" "later"]];
  overlay = _final: prev: {
    ai = prev.ai // {later = "later";};
  };
}
