# The INNER EMITTER of MECH-EMIT-LAYER-BOUNDARY
# (docs/plans/strictdoc-tooling/mech-emit-layer-boundary.sdoc): it takes values
# that are already all strings, knows the FILE FORMAT, and does no encoding at
# all. A pure renderer.
#
# It therefore takes no `normalized` and holds no encoder. That is the whole
# test of the split, and it is machine-checkable: an encoder appearing here
# would need `lib.types`' other half to justify it, and this file cannot reach
# it. The encode halves live in ./denormalize.nix, and ./emit.nix is the two
# composed.
#
# THIS FILE NAME IS NOT A PUBLIC NAME. What the inner emitter is called, and
# whether it is exposed at all, is deliberately open (see that node's NOTES);
# nothing outside ./emit.nix reaches this file today.
#
# INPUT CONTRACT — what ./denormalize.nix hands over, and what a hand-written
# caller would have to build:
#
#   element   {tag; isComposite; prefix; viewStyle; fields = [ … ];
#              relations = [ … ];}
#   field     {<kind> = {title; humanTitle; required; choices;};}
#   relation  {<type> = {role; reverseRole;};}
#
# Every leaf is a STRING or `null`, and null means "omit the line" — the record
# is total, so a key is never merely absent. `choices` arrives already joined
# and already quoted where quoting was needed; `required` is already the literal
# `True` or `False`, and is never null, because REQUIRED is mandatory on every
# field in the grammar. Structure is NOT flattened: the element / field /
# relation lists and the field-kind and relation-type tags are what this file
# renders from.
#
# Order is load-bearing at every level, which is why the surface uses lists and
# not attribute sets: StrictDoc enforces element, field and relation order, and
# Nix sorts attribute-set keys. The consequence lands here — the renderer emits
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
{lib, ...}: let
  inherit (lib) concatMapStrings concatStringsSep optionalString;

  fail = msg: throw "packages/strictdoc-grammar/lib/sgra.nix: ${msg}";

  ## Line helpers #############################################################

  # `KEY: value` at `indent`, or nothing at all when the value is null.
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
  #
  # This is format knowledge rather than type knowledge — it is about what the
  # file means to the reader that parses it — so it stays on this side of the
  # split, alongside the lists it reads.
  duplicates = xs: lib.unique (lib.filter (x: lib.count (y: y == x) xs > 1) xs);

  # (type, role) as an unambiguous key. Via toJSON so a null role cannot
  # collide with a role literally spelled "null".
  relationKey = name: body: builtins.toJSON [name body.role];

  ## Field ####################################################################

  fieldTypeText = kindName: body: let
    # Already a `", "`-joined, already-quoted vocabulary string. Lazy, so the
    # two spellings that take no vocabulary never force it — an extra `choices`
    # on a `String` field is simply not rendered.
    vocabulary =
      if body.choices == null
      then fail "field kind '${kindName}' has no `choices`"
      else body.choices;

    # The four TYPE spellings, and there are no others.
    spellings = {
      string = "String";
      tag = "Tag";
      singleChoice = "SingleChoice(${vocabulary})";
      multipleChoice = "MultipleChoice(${vocabulary})";
    };
  in
    spellings.${kindName} or (fail "unknown field kind '${kindName}'");

  # A field is the attrTag itself: each of the four `GrammarElementField*` rules
  # carries its own TITLE / HUMAN_TITLE / REQUIRED production, so `title` lives
  # INSIDE the chosen alternative rather than beside it. Same shape as
  # `relation` below, for the same reason.
  fieldBodyOf = f: f.${lib.head (lib.attrNames f)};

  field = f: let
    kindNames = lib.attrNames f;
    kindName = lib.head kindNames;
    body = f.${kindName};
  in
    if lib.length kindNames != 1
    then fail "a field must carry exactly one kind, got ${toString (lib.length kindNames)}"
    else if body.title == null
    then fail "a field of kind '${kindName}' has no TITLE"
    else
      "  - TITLE: ${body.title}\n"
      + optionalLine "    " "HUMAN_TITLE" body.humanTitle
      + "    TYPE: ${fieldTypeText kindName body}\n"
      # REQUIRED is mandatory on every field, so it is emitted unconditionally
      # rather than skipped when false. `denormalize` defaults it, which is why
      # there is no `False` literal anywhere in this file.
      + "    REQUIRED: ${body.required}\n";

  ## Relation #################################################################

  # How the FILE spells each relation production — a constant of the format, the
  # exact counterpart of `spellings` above, and not an encoded value. The
  # discriminator is structure, so it survives denormalization untouched.
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
    else if name == "file" && body.reverseRole != null
    then fail "the File relation has no REVERSE_ROLE production"
    else
      "  - TYPE: ${relationTags.${name}}\n"
      + optionalLine "    " "ROLE" body.role
      + optionalLine "    " "REVERSE_ROLE" body.reverseRole;

  ## Element ##################################################################

  element = e: let
    where = "element '${
      if e.tag == null
      then "<untagged>"
      else e.tag
    }'";
    dupTitles = duplicates (map (f: (fieldBodyOf f).title) e.fields);
    dupRelations = duplicates (map (r: let n = lib.head (lib.attrNames r); in relationKey n r.${n}) e.relations);
  in
    if e.tag == null
    then fail "an element needs a TAG"
    else if e.fields == []
    then fail "${where} needs at least one field"
    else if dupTitles != []
    then fail "${where} has duplicate field titles: ${concatStringsSep ", " dupTitles} (strictdoc keeps the LAST, silently)"
    else if dupRelations != []
    then fail "${where} has duplicate relation (type, role) pairs: ${concatStringsSep " " dupRelations} (strictdoc keeps the FIRST, silently)"
    else
      "- TAG: ${e.tag}\n"
      + optionalString (e.isComposite != null || e.prefix != null || e.viewStyle != null) (
        "  PROPERTIES:\n"
        + optionalLine "    " "IS_COMPOSITE" e.isComposite
        + optionalLine "    " "PREFIX" e.prefix
        + optionalLine "    " "VIEW_STYLE" e.viewStyle
      )
      + "  FIELDS:\n"
      + concatMapStrings field e.fields
      + optionalString (e.relations != []) (
        "  RELATIONS:\n" + concatMapStrings relation e.relations
      );

  ## File #####################################################################

  # `elements += GrammarElement` is a one-or-more repetition, so an `ELEMENTS:`
  # header with nothing under it does not parse. Every element already ends in
  # a newline, so the file needs no terminator appended.
  #
  # A null tag is filtered out of the duplicate scan rather than compared: the
  # element renderer below names that failure properly, and two untagged
  # elements are not "duplicate tags".
  grammar = elements: let
    dupTags = duplicates (lib.filter (tag: tag != null) (map (e: e.tag) elements));
  in
    if elements == []
    then fail "a grammar needs at least one element"
    else if dupTags != []
    then fail "duplicate element tags: ${concatStringsSep ", " dupTags} (strictdoc keeps the LAST, silently)"
    else "[GRAMMAR]\nELEMENTS:\n" + concatMapStrings element elements;
in
  # One renderer per node type, and NOTHING else: ./emit.nix composes over these
  # attribute names, so an attribute here that is not a renderer would be
  # composed as one.
  {
    inherit element field grammar relation;
  }
