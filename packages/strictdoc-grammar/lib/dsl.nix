# Hand-written consumer DSL over ./normalized.nix. Sugar only: it cannot weaken
# the types, it only saves typing. The shape is settled in
# ../docs/implementation-brief.md ("Consumer DSL, hand-written, mapping onto
# that") — implement that shape, do not redesign it.
#
# Two things the brief fixes and a reader will otherwise get wrong:
#   - There is NO `optional` constructor. Absence of `required` is optional.
#   - `raw` is identity. It escapes the CONSTRUCTORS, never the surface: `raw`
#     with choices on a string kind, two kinds at once, or an unknown kind are
#     all rejected by the types.
#
# SCAFFOLD STUB — every constructor throws when applied. Each is a lambda so the
# attrset still deep-evaluates.
#
# Eventual signature: `{lib, normalized}:`. `_:` here so the stub ignores the
# arguments the barrel passes without tripping deadnix.
_: let
  todo = name:
    throw "packages/strictdoc-grammar/lib/dsl.nix: ${name} is a scaffold stub (SLICE-GRAMMAR-FROM-NIX milestone 1)";
in {
  # Field constructors. `mk` is the general form the other four specialize.
  field = {
    mk = _kind: _title: _body: todo "field.mk";
    str = _title: todo "field.str";
    tag = _title: todo "field.tag";
    one = _title: _choices: todo "field.one";
    many = _title: _choices: todo "field.many";
    required = _field: todo "field.required";
    raw = x: x;
  };

  # Relation constructors. Parent and Child take an optional ROLE and
  # REVERSE_ROLE; File takes ROLE and has no REVERSE_ROLE production at all, so
  # `file` deliberately has a different arity from its two siblings. The brief's
  # sketch writes `file` as a bare value; whether it stays one or takes a role
  # is the implementing session's call.
  rel = {
    parent = _role: _reverseRole: todo "rel.parent";
    child = _role: _reverseRole: todo "rel.child";
    file = _role: todo "rel.file";
    raw = x: x;
  };

  # Element constructor: tag, then the optional PROPERTIES block, then the
  # FIELDS / RELATIONS body.
  el = _tag: _props: _body: todo "el";
}
