# Echoing existing values is not a write and must not hide the missing leaf.
_context: {
  claims = [["ai" "shared"]];
  overlay = _final: prev: {inherit (prev) ai;};
}
