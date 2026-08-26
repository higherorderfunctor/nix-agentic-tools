# Hand-written consumer DSL over ./normalized.nix. Sugar only: it cannot weaken
# the types, it only saves typing. The shape is settled in
# ../docs/implementation-brief.md ("Consumer DSL, hand-written, mapping onto
# that") — this file implements that shape, it does not redesign it.
#
# Two things the brief fixes and a reader will otherwise get wrong:
#   - There is NO `optional` constructor. Absence of `required` is optional.
#   - `raw` is identity. It escapes the CONSTRUCTORS, never the surface: `raw`
#     with choices on a string kind, two kinds at once, or an unknown kind are
#     all rejected by the types.
#
# Nothing here asserts, defaults or coerces. Every constructor is a plain
# attrset literal, so the only thing that can reject a value is the normalized
# option surface it is checked against — which is exactly what "sugar only"
# has to mean for it to be true rather than aspirational.
#
# WHY `normalized` IS ACCEPTED AND IGNORED. The barrel passes it (see
# ./default.nix) and the eventual signature in that file names it, but the DSL
# is value-level: types flow up from strictdoc into ./normalized.nix, values
# flow down from here into ./emit.nix, and the two meet when a value is checked
# against `normalized.types`. Reading the types here would either duplicate
# that check or, at this stage, run against an empty placeholder surface and
# reject everything. `...` keeps the barrel's call site honest without naming an
# argument this file has no business reading.
#
# GENERIC CONSTRUCTORS. `field.mk` and `rel.mk` are the general forms the named
# constructors specialize. They exist so that a field type or relation type
# added upstream — the surface is generated, upstream ships ~3 releases a month
# — is writable the day it appears, without this hand-written file being the
# thing that has to be edited first. `mk` names the tag; `attrTag` still decides
# whether that tag exists.
#
# ARITY. `parent` and `child` take both roles positionally; `file` is a bare
# value, because the File relation has no REVERSE_ROLE production at all
# (MEASURED). A role-less parent, or a File carrying a ROLE, is written with
# `rel.mk` — the named constructors cover the common case, not every case.
#
# Worked example. All four field types and all three relation kinds:
#
#   (el "EXAMPLE" {prefix = "EX-";} {
#     fields = [
#       (field.required (field.str "UID"))
#       (field.tag "LABELS")
#       (field.one "STATUS" ["Draft" "Active"])
#       (field.many "OWNERS" ["ops" "docs"])
#     ];
#     relations = [
#       (rel.parent "Refines" "Refined_By")
#       (rel.child "Parent_Of" "Child_Of")
#       rel.file
#     ];
#   })
#
#   => {
#     tag = "EXAMPLE";
#     prefix = "EX-";
#     fields = [
#       {title = "UID";    kind.string         = {required = true;};}
#       {title = "LABELS"; kind.tag            = {};}
#       {title = "STATUS"; kind.singleChoice   = {choices = ["Draft" "Active"];};}
#       {title = "OWNERS"; kind.multipleChoice = {choices = ["ops" "docs"];};}
#     ];
#     relations = [
#       {parent = {role = "Refines";   reverseRole = "Refined_By";};}
#       {child  = {role = "Parent_Of"; reverseRole = "Child_Of";};}
#       {file = {};}
#     ];
#   }
{lib, ...}: {
  # Field constructors. `mk` is the general form the other four specialize.
  field = rec {
    mk = kindName: title: body: {
      inherit title;
      kind.${kindName} = body;
    };

    str = title: mk "string" title {};
    tag = title: mk "tag" title {};
    one = title: choices: mk "singleChoice" title {inherit choices;};
    many = title: choices: mk "multipleChoice" title {inherit choices;};

    # REQUIRED is a property of the field's TYPE body, not of the field, so it
    # is set through the single tag `kind` carries. Written as a mapAttrs rather
    # than by naming the tag so it works for any kind, including one `mk`
    # reached that has no named constructor here.
    #
    # There is deliberately no `optional`: absence is optional.
    required = field: field // {kind = lib.mapAttrs (_: body: body // {required = true;}) field.kind;};

    raw = x: x;
  };

  # Relation constructors. See ARITY above for why `file` is a bare value.
  rel = rec {
    mk = typeName: body: {${typeName} = body;};

    parent = role: reverseRole: mk "parent" {inherit role reverseRole;};
    child = role: reverseRole: mk "child" {inherit role reverseRole;};
    file = mk "file" {};

    raw = x: x;
  };

  # Element constructor: tag, then the optional PROPERTIES block, then the
  # FIELDS / RELATIONS body. `props` and `body` are merged rather than named so
  # a property added upstream needs no edit here.
  el = tag: props: body: {inherit tag;} // props // body;
}
