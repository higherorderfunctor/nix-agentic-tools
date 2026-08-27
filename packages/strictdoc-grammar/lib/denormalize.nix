# The TYPE MAPPING half of MECH-EMIT-LAYER-BOUNDARY
# (docs/plans/strictdoc-tooling/99-backlog.sdoc): NORMALIZED values in, the same
# shape out with every leaf already a string. A Nix bool becomes the literal
# `True` or `False`, an enum member becomes its bare string, a list becomes a
# `", "` join.
#
# Every converter is a PAIR: a type rewrite (decomposed type -> normalized type)
# and an encoder (normalized value -> faithful value, on the way to the file).
# ./normalized.nix is generated and carries the type-rewrite halves; this file
# applies the encode halves, and ./sgra.nix — which sees only the strings that
# come out of here — carries no encoder at all.
#
# ENCODE ONLY. There is no decoder — reading `.sgra` back into Nix is out of
# scope, so nothing here needs to round-trip through a parser.
#
# WHAT STAYS STRUCTURE. The element / field / relation lists, the field-kind tag
# and the relation-type tag are not values and are passed through untouched:
# they are what ./sgra.nix renders FROM, and the file's own spelling of each
# ("String", "Parent", …) is a constant of the format rather than an encoded
# value.
#
# ABSENCE. Every optional comes out as `null` rather than as a missing key, so
# the record ./sgra.nix receives is total. A value reaching here through
# ./check.nix already has that shape; one written by hand may leave the key off
# entirely, which is why every read below goes through `or null`. `required` is
# the exception the grammar forces: REQUIRED is mandatory on every field, so an
# omitted one is defaulted here rather than left for the renderer to invent.
#
# CARDINALITY OF A VALUE LIST is checked here for the same reason — ./sgra.nix
# never sees the choice list, only the string it joined to, so this is the last
# layer that can say anything about it.
{
  lib,
  normalized ? {},
  ...
}: let
  fail = msg: throw "packages/strictdoc-grammar/lib/denormalize.nix: ${msg}";

  ## Encoders — the second half of each converter pair #########################
  #
  # The GENERATED ./normalized.nix ships its own under these names and wins;
  # a name it does not carry keeps the local one, which emits the same bytes
  # either way.
  defaultEncoders = {
    # `strMatching "(True|False)"` decomposed, `types.bool` normalized.
    bool = b:
      if b
      then "True"
      else "False";

    # An enum value goes back as its bare string. Never quoted: the grammar
    # matches the literal alternation directly.
    enum = v: v;

    # A string that was already a string. Named rather than skipped so that
    # "this value is carried through unchanged" is a converter half like any
    # other, and so a future rewrite has one place to land.
    str = s: s;

    # A choice option is quoted ONLY when it contains a parenthesis. That is
    # exactly what `GrammarElementFieldSingleChoice.get_unprocessed_options`
    # does, and byte-identity depends on matching it. Quoting buys literal
    # parentheses and nothing else — an option may not contain a comma in
    # either form, because the separator is unconditionally `", "`.
    #
    # Deliberately absent from ./normalized.nix: this rule comes from
    # strictdoc's WRITER, not from the grammar that file is derived from, so it
    # is not that layer's to own. It is still an encoder, so it is this one's.
    choiceOption = o:
      if lib.hasInfix "(" o || lib.hasInfix ")" o
      then ''"${o}"''
      else o;

    # A list goes back as a `", "`-joined string.
    list = xs: lib.concatStringsSep ", " xs;
  };

  enc = defaultEncoders // (normalized.encoders or {});

  # Absence survives encoding: null in, null out, and no encoder is handed a
  # value that is not of its type.
  optional = encoder: value:
    if value == null
    then null
    else encoder value;

  ## Field ####################################################################
  #
  # `mapAttrs` over the attrTag rather than a lookup of the single kind: this
  # layer does not decide whether the field is well-formed, it encodes whatever
  # kinds are there. A field carrying two kinds, or a kind that does not exist,
  # reaches ./sgra.nix intact and is rejected there — by the layer that knows
  # what the file can spell.
  #
  # Which keys mean something for which kind is likewise not decided here. A
  # stray `choices` on a `String` field is encoded and then never rendered,
  # which is exactly what it did before the split.
  fieldBody = kindName: body: {
    title = enc.str body.title;
    humanTitle = optional enc.str (body.humanTitle or null);

    # The grammar makes REQUIRED mandatory; the surface gives it no default, so
    # a value that omits it does not type-check. Reaching here without one means
    # the type check was bypassed, and `False` is what that has always rendered.
    required = enc.bool (body.required or false);

    # Lazy, so a kind that takes no vocabulary never forces it — including the
    # empty-list rejection.
    choices =
      if !(body ? choices)
      then null
      else if body.choices == []
      then fail "field kind '${kindName}' needs at least one choice"
      else enc.list (map enc.choiceOption body.choices);
  };

  field = lib.mapAttrs fieldBody;

  ## Relation #################################################################

  relationBody = _: body: {
    role = optional enc.str (body.role or null);
    reverseRole = optional enc.str (body.reverseRole or null);
  };

  relation = lib.mapAttrs relationBody;

  ## Element ##################################################################

  element = e: {
    tag = optional enc.str (e.tag or null);
    isComposite = optional enc.bool (e.isComposite or null);
    prefix = optional enc.str (e.prefix or null);
    viewStyle = optional enc.enum (e.viewStyle or null);
    fields = map field (e.fields or []);

    # `relations` is `nullOr (nonEmptyListOf …)` on the surface and defaults to
    # null, so a checked value spells "no relations" as null while a
    # hand-written one may leave the key off or write `[]`. All three mean the
    # same file, and the renderer sees one of them.
    relations = map relation (
      if (e.relations or null) == null
      then []
      else e.relations
    );
  };

  ## File #####################################################################

  grammar = map element;
in {
  inherit element field grammar relation;

  # The encode halves, exposed so a converter pair can be audited from either
  # end rather than only through rendered output.
  encoders = enc;
}
