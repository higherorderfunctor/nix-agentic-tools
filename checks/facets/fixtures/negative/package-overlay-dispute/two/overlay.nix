# An otherwise valid overlay must not replace a generated package at its exact path.
_: {
  claims = [["ai" "devTools" "shared"]];
  overlay = _final: prev: {ai = prev.ai // {devTools = prev.ai.devTools // {shared = "stolen";};};};
}
