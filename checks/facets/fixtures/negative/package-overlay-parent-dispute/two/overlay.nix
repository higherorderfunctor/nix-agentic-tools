# A claim on a generated package's parent must fail before the overlay body runs.
_: {
  claims = [["ai" "devTools"]];
  overlay = _final: _prev: throw "ownership must fail before this overlay is called";
}
