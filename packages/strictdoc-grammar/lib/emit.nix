# Renders `.sgra` source text from NORMALIZED values, running each value
# through ./normalized.nix's encoder on the way out.
#
# ENCODE ONLY. There is no decoder — reading `.sgra` back into Nix is out of
# scope, so nothing here needs to round-trip through a parser.
#
# Order is load-bearing at every level, which is why the surface uses lists and
# not attribute sets: StrictDoc enforces element, field and relation order, and
# Nix sorts attribute-set keys. The consequence lands here — the emitter renders
# a list in the order given, and duplicate detection is an explicit assertion
# rather than a structural side effect.
#
# SCAFFOLD STUB — every renderer throws when applied. Each is a lambda so the
# attrset still deep-evaluates.
#
# Eventual signature: `{lib, normalized}:`. `_:` here so the stub ignores the
# arguments the barrel passes without tripping deadnix.
_: let
  todo = name:
    throw "packages/strictdoc-grammar/lib/emit.nix: ${name} is a scaffold stub (SLICE-GRAMMAR-FROM-NIX milestone 1)";
in {
  # The whole file: a list of elements -> the complete `.sgra` source string.
  grammar = _elements: todo "grammar";

  # One `[GRAMMAR_ELEMENT]` block.
  element = _element: todo "element";

  # One entry of an element's mandatory FIELDS block.
  field = _field: todo "field";

  # One entry of an element's optional RELATIONS block.
  relation = _relation: todo "relation";
}
