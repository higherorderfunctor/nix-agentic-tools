# Renders `.sgra` source text from NORMALIZED values, running each value
# through its encoder on the way out.
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
# The emission ORDER below is not a layout choice; it is transcribed from
# strictdoc's own writer (`backend/sdoc/writer.py`, 0.28.3) and from the grammar
# it must parse back through (`backend/sdoc/grammar/grammar_grammar.py`):
#
#   element   TAG, PROPERTIES (only when at least one property is non-null, in
#             the order IS_COMPOSITE / PREFIX / VIEW_STYLE), FIELDS,
#             RELATIONS (only when non-empty)
#   field     TITLE, HUMAN_TITLE (optional), TYPE, REQUIRED — REQUIRED always
#   relation  TYPE, ROLE (optional), REVERSE_ROLE (optional; never for File,
#             which has no REVERSE_ROLE production at all)
{
  lib,
  normalized ? {},
  ...
}: let
  inherit (lib) concatMapStrings concatStringsSep optionalString;

  fail = msg: throw "packages/strictdoc-grammar/lib/emit.nix: ${msg}";

  ## Encoders — the second half of each converter pair #########################
  #
  # A converter is a type rewrite (faithful type -> normalized type) plus an
  # encoder (normalized value -> faithful value). The type rewrites live in the
  # GENERATED ./normalized.nix; these are their encode halves. When that file
  # starts shipping its own under the same names it wins — a name that does not
  # match simply keeps the local pair, which emits the same bytes either way.
  defaultEncoders = {
    # `strMatching "(True|False)"` faithfully, `types.bool` normalized.
    bool = b:
      if b
      then "True"
      else "False";

    # An enum value goes back as its bare string. Never quoted: the grammar
    # matches the literal alternation directly.
    enum = v: v;

    # A choice option is quoted ONLY when it contains a parenthesis. That is
    # exactly what `GrammarElementFieldSingleChoice.get_unprocessed_options`
    # does, and byte-identity depends on matching it. Quoting buys literal
    # parentheses and nothing else — an option may not contain a comma in
    # either form, because the separator is unconditionally `", "`.
    choiceOption = o:
      if lib.hasInfix "(" o || lib.hasInfix ")" o
      then ''"${o}"''
      else o;

    # A list goes back as a `", "`-joined string.
    list = xs: concatStringsSep ", " xs;
  };

  enc = defaultEncoders // (normalized.encoders or {});

  ## Line helpers #############################################################

  # `KEY: value` at `indent`, or nothing at all when the value is absent.
  # Absent is `null` — the surface defaults an unset optional to null, and a
  # value spread in by the DSL's `el` may leave the key off entirely, so every
  # read below goes through `or null`.
  optionalLine = indent: key: value:
    optionalString (value != null) "${indent}${key}: ${value}\n";

  ## Duplicate detection ######################################################
  #
  # Silent collisions strictdoc has no rule for anywhere: each parses clean and
  # exports exit 0, and they do not even fail in the same direction. Duplicate
  # element TAGs and duplicate field titles are dict assignments, so they keep
  # the LAST; duplicate relations are a scan for the first matching (type, role)
  # pair, so they keep the FIRST.
  #
  # The brief names two of these. The element-TAG case is a third, measured the
  # same way during this milestone (`DocumentGrammar.elements_by_type[tag] =
  # element`, 0.28.3) and guarded here for the same reason.
  duplicates = xs: lib.unique (lib.filter (x: lib.count (y: y == x) xs > 1) xs);

  # (type, role) as an unambiguous key. Via toJSON so a null role cannot
  # collide with a role literally spelled "null".
  relationKey = name: body: builtins.toJSON [name (body.role or null)];

  ## Field ####################################################################

  fieldTypeText = kindName: body: let
    options = let
      cs = body.choices or (fail "field kind '${kindName}' has no `choices`");
    in
      if cs == []
      then fail "field kind '${kindName}' needs at least one choice"
      else enc.list (map enc.choiceOption cs);

    # The four TYPE spellings, and there are no others. `options` is lazy, so
    # the two that do not take a vocabulary never force it.
    spellings = {
      string = "String";
      tag = "Tag";
      singleChoice = "SingleChoice(${options})";
      multipleChoice = "MultipleChoice(${options})";
    };
  in
    spellings.${kindName} or (fail "unknown field kind '${kindName}'");

  field = f: let
    kindNames = lib.attrNames (f.kind or {});
    kindName = lib.head kindNames;
    body = f.kind.${kindName};
  in
    if lib.length kindNames != 1
    then fail "field '${f.title or "<untitled>"}' must carry exactly one kind, got ${toString (lib.length kindNames)}"
    else
      "  - TITLE: ${f.title}\n"
      + optionalLine "    " "HUMAN_TITLE" (f.humanTitle or null)
      + "    TYPE: ${fieldTypeText kindName body}\n"
      # REQUIRED is mandatory on every field, so it is emitted unconditionally
      # rather than skipped when false.
      + "    REQUIRED: ${enc.bool (body.required or false)}\n";

  ## Relation #################################################################

  relationTags = {
    parent = "Parent";
    child = "Child";
    file = "File";
  };

  relation = r: let
    names = lib.attrNames r;
    name = lib.head names;
    body = r.${name};
  in
    if lib.length names != 1
    then fail "relation must carry exactly one type, got ${toString (lib.length names)}"
    else if !(relationTags ? ${name})
    then fail "unknown relation type '${name}'"
    else if name == "file" && (body.reverseRole or null) != null
    then fail "the File relation has no REVERSE_ROLE production"
    else
      "  - TYPE: ${enc.enum relationTags.${name}}\n"
      + optionalLine "    " "ROLE" (body.role or null)
      + optionalLine "    " "REVERSE_ROLE" (body.reverseRole or null);

  ## Element ##################################################################

  element = e: let
    isComposite = e.isComposite or null;
    prefix = e.prefix or null;
    viewStyle = e.viewStyle or null;
    fields = e.fields or [];
    relations = e.relations or [];

    where = "element '${e.tag or "<untagged>"}'";
    dupTitles = duplicates (map (f: f.title) fields);
    dupRelations = duplicates (map (r: let n = lib.head (lib.attrNames r); in relationKey n r.${n}) relations);
  in
    if fields == []
    then fail "${where} needs at least one field"
    else if dupTitles != []
    then fail "${where} has duplicate field titles: ${concatStringsSep ", " dupTitles} (strictdoc keeps the LAST, silently)"
    else if dupRelations != []
    then fail "${where} has duplicate relation (type, role) pairs: ${concatStringsSep " " dupRelations} (strictdoc keeps the FIRST, silently)"
    else
      "- TAG: ${e.tag}\n"
      + optionalString (isComposite != null || prefix != null || viewStyle != null) (
        "  PROPERTIES:\n"
        + optionalString (isComposite != null) "    IS_COMPOSITE: ${enc.bool isComposite}\n"
        + optionalLine "    " "PREFIX" prefix
        + optionalLine "    " "VIEW_STYLE" (
          if viewStyle == null
          then null
          else enc.enum viewStyle
        )
      )
      + "  FIELDS:\n"
      + concatMapStrings field fields
      + optionalString (relations != []) (
        "  RELATIONS:\n" + concatMapStrings relation relations
      );

  ## File #####################################################################

  # `elements += GrammarElement` is a one-or-more repetition, so an `ELEMENTS:`
  # header with nothing under it does not parse. Every element already ends in
  # a newline, so the file needs no terminator appended.
  grammar = elements: let
    dupTags = duplicates (map (e: e.tag) elements);
  in
    if elements == []
    then fail "a grammar needs at least one element"
    else if dupTags != []
    then fail "duplicate element tags: ${concatStringsSep ", " dupTags} (strictdoc keeps the LAST, silently)"
    else "[GRAMMAR]\nELEMENTS:\n" + concatMapStrings element elements;
in {
  inherit element field grammar relation;

  # The encode halves, exposed so a converter pair can be audited from either
  # end rather than only through rendered output.
  encoders = enc;
}
