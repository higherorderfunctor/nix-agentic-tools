# GENERATED FILE — DO NOT EDIT BY HAND.
#
# Written by packages/strictdoc-grammar/extract/normalize.py from ./faithful.nix.
#
# NORMALIZED is the typed surface, and the whole decomposition happens on this
# side of the line. ./faithful.nix carries the grammar's own production tree
# with every pattern exactly as upstream spells it; the `types` block below is
# built from those records — the POSIX dialect rewrite, the lookahead groups
# lifted out of a pattern, the alternations read as vocabularies — and every
# rewrite performed is NAMED where it was performed. The body is `faithful //
# { … }`, so `productions` and `meta` come through unchanged.
#
# Every converter is a PAIR: a type rewrite (decomposed type -> normalized type)
# and an encoder (normalized value -> faithful value, on the way to the file).
# `IS_COMPOSITE` is `strMatching "(True|False)"` decomposed and `types.bool`
# normalized, so its encoder is `b: if b then "True" else "False"`.
#
# Encode only. There is no decoder; reading `.sgra` back into Nix is out of
# scope.
#
# An unrecognized shape is an ERROR, not a fallback to free text — declaring a
# value unconstrained is itself a named converter, so "we decided this is free
# text" stays distinguishable from "nobody classified this". `converters.applied`
# below is the complete census: every node of the surface, and the named
# converter that claimed it.
#
# `encoders` is keyed the way ./emit.nix reads it, which merges
# `defaultEncoders // normalized.encoders` — a name here wins, a name missing
# here keeps emit.nix's own. `choiceOption` is deliberately absent: that quoting
# rule comes from strictdoc's writer, not from the grammar, so it is not this
# layer's to own.
{
  lib,
  faithful,
  ...
}: let
  t = lib.types;
  inherit (lib) mkOption;
  patternType = p:
  # `p.ere` is p.source in the dialect `builtins.match` speaks; `p.deny`
  # carries the negative lookahead groups that dialect cannot spell, checked
  # as prefix rejections instead. `.*` is deliberate: Nix's `.` matches a
  # newline, so a denied prefix is caught wherever the rest of the string
  # goes.
  #
  # A `^`-anchored lookahead is in `p.deny` too when the word it denies is an
  # alternative of nothing — a real reservation rather than a backtracking
  # guard. `p.denyAtLineStart` is the other half of that split: recorded,
  # deliberately inert, and never a constraint on the value alone.
    if p.deny == []
    then t.strMatching p.ere
    else
      t.addCheck (t.strMatching p.ere)
      (s: !(lib.any (d: builtins.match "(${d}).*" s != null) p.deny));
in
  faithful
  // {
    converters = {
      applied = {
        "types.BooleanChoice" = "boolean";
        "types.ChoiceOption" = "decodedOption";
        "types.ChoiceOptionXs" = "alias";
        "types.DocumentGrammar" = "submodule";
        "types.DocumentGrammar.options.elements.type" = "optionalGroup";
        "types.DocumentGrammar.options.elements.type.nullOr" = "oneOrMore";
        "types.DocumentGrammar.options.elements.type.nullOr.nonEmptyListOf" = "ruleReference";
        "types.DocumentGrammar.options.importFromFile.type" = "optionalGroup";
        "types.DocumentGrammar.options.importFromFile.type.nullOr" = "unconstrained";
        "types.DocumentGrammarWrapper" = "submodule";
        "types.DocumentGrammarWrapper.options.grammar.type" = "ruleReference";
        "types.FieldName" = "regexPreserved";
        "types.GrammarElement" = "submodule";
        "types.GrammarElement.options.fields.type" = "oneOrMore";
        "types.GrammarElement.options.fields.type.nonEmptyListOf" = "ruleReference";
        "types.GrammarElement.options.isComposite.type" = "optionalGroup";
        "types.GrammarElement.options.isComposite.type.nullOr" = "boolean";
        "types.GrammarElement.options.prefix.type" = "optionalGroup";
        "types.GrammarElement.options.prefix.type.nullOr" = "unconstrained";
        "types.GrammarElement.options.relations.type" = "optionalGroup";
        "types.GrammarElement.options.relations.type.nullOr" = "oneOrMore";
        "types.GrammarElement.options.relations.type.nullOr.nonEmptyListOf" = "ruleReference";
        "types.GrammarElement.options.tag.type" = "ruleReference";
        "types.GrammarElement.options.viewStyle.type" = "optionalGroup";
        "types.GrammarElement.options.viewStyle.type.nullOr" = "literalAlternation";
        "types.GrammarElementField" = "attrTag";
        "types.GrammarElementField.multipleChoice.type" = "ruleReference";
        "types.GrammarElementField.singleChoice.type" = "ruleReference";
        "types.GrammarElementField.string.type" = "ruleReference";
        "types.GrammarElementField.tag.type" = "ruleReference";
        "types.GrammarElementFieldMultipleChoice" = "submodule";
        "types.GrammarElementFieldMultipleChoice.options.choices.type" = "commaList";
        "types.GrammarElementFieldMultipleChoice.options.choices.type.nonEmptyListOf" = "ruleReference";
        "types.GrammarElementFieldMultipleChoice.options.humanTitle.type" = "optionalGroup";
        "types.GrammarElementFieldMultipleChoice.options.humanTitle.type.nullOr" = "ruleReference";
        "types.GrammarElementFieldMultipleChoice.options.required.type" = "ruleReference";
        "types.GrammarElementFieldMultipleChoice.options.title.type" = "ruleReference";
        "types.GrammarElementFieldSingleChoice" = "submodule";
        "types.GrammarElementFieldSingleChoice.options.choices.type" = "commaList";
        "types.GrammarElementFieldSingleChoice.options.choices.type.nonEmptyListOf" = "ruleReference";
        "types.GrammarElementFieldSingleChoice.options.humanTitle.type" = "optionalGroup";
        "types.GrammarElementFieldSingleChoice.options.humanTitle.type.nullOr" = "ruleReference";
        "types.GrammarElementFieldSingleChoice.options.required.type" = "ruleReference";
        "types.GrammarElementFieldSingleChoice.options.title.type" = "ruleReference";
        "types.GrammarElementFieldString" = "submodule";
        "types.GrammarElementFieldString.options.humanTitle.type" = "optionalGroup";
        "types.GrammarElementFieldString.options.humanTitle.type.nullOr" = "ruleReference";
        "types.GrammarElementFieldString.options.required.type" = "ruleReference";
        "types.GrammarElementFieldString.options.title.type" = "ruleReference";
        "types.GrammarElementFieldTag" = "submodule";
        "types.GrammarElementFieldTag.options.humanTitle.type" = "optionalGroup";
        "types.GrammarElementFieldTag.options.humanTitle.type.nullOr" = "ruleReference";
        "types.GrammarElementFieldTag.options.required.type" = "ruleReference";
        "types.GrammarElementFieldTag.options.title.type" = "ruleReference";
        "types.GrammarElementRelation" = "attrTag";
        "types.GrammarElementRelation.child.type" = "ruleReference";
        "types.GrammarElementRelation.file.type" = "ruleReference";
        "types.GrammarElementRelation.parent.type" = "ruleReference";
        "types.GrammarElementRelationChild" = "submodule";
        "types.GrammarElementRelationChild.options.reverseRole.type" = "optionalGroup";
        "types.GrammarElementRelationChild.options.reverseRole.type.nullOr" = "unconstrained";
        "types.GrammarElementRelationChild.options.role.type" = "optionalGroup";
        "types.GrammarElementRelationChild.options.role.type.nullOr" = "unconstrained";
        "types.GrammarElementRelationChild.options.type.type" = "namedChoice";
        "types.GrammarElementRelationFile" = "submodule";
        "types.GrammarElementRelationFile.options.role.type" = "optionalGroup";
        "types.GrammarElementRelationFile.options.role.type.nullOr" = "unconstrained";
        "types.GrammarElementRelationFile.options.type.type" = "namedChoice";
        "types.GrammarElementRelationParent" = "submodule";
        "types.GrammarElementRelationParent.options.reverseRole.type" = "optionalGroup";
        "types.GrammarElementRelationParent.options.reverseRole.type.nullOr" = "unconstrained";
        "types.GrammarElementRelationParent.options.role.type" = "optionalGroup";
        "types.GrammarElementRelationParent.options.role.type.nullOr" = "unconstrained";
        "types.GrammarElementRelationParent.options.type.type" = "namedChoice";
        "types.RequirementType" = "regexPreserved";
        "types.ReservedKeyword" = "namedChoice";
        "types.SingleLineString" = "regexPreserved";
      };
      detail = {
        "types.BooleanChoice" = "'True|False' via namedChoice";
        "types.ChoiceOption" = "ChoiceOption -- the decoded option, not the token. A comma is excluded in both spellings because the separator is unconditionally ', '; a double quote is excluded so the encoder's quoting round-trips; a parenthesis is allowed here and quoted on the way out";
        "types.ChoiceOptionXs" = "ChoiceOption";
        "types.DocumentGrammar.options.elements.type" = "unset is null, not missing";
        "types.DocumentGrammar.options.elements.type.nullOr" = "`elements += …` in DocumentGrammar";
        "types.DocumentGrammar.options.elements.type.nullOr.nonEmptyListOf" = "GrammarElement";
        "types.DocumentGrammar.options.importFromFile.type" = "unset is null, not missing";
        "types.DocumentGrammar.options.importFromFile.type.nullOr" = "'.+\$' constrains nothing but emptiness";
        "types.DocumentGrammarWrapper.options.grammar.type" = "DocumentGrammar";
        "types.FieldName" = "FieldName — a character class with a quantifier, plus two lifted lookahead groups; enforced denials 'RELATIONS'; recorded but not enforced, being alternatives of the rule that denies them: 'UID'";
        "types.GrammarElement.options.fields.type" = "`fields += …` in GrammarElement";
        "types.GrammarElement.options.fields.type.nonEmptyListOf" = "GrammarElementField";
        "types.GrammarElement.options.isComposite.type" = "unset is null, not missing";
        "types.GrammarElement.options.isComposite.type.nullOr" = "'(True|False)' via literalAlternation";
        "types.GrammarElement.options.prefix.type" = "unset is null, not missing";
        "types.GrammarElement.options.prefix.type.nullOr" = "'.*' constrains nothing but emptiness";
        "types.GrammarElement.options.relations.type" = "unset is null, not missing";
        "types.GrammarElement.options.relations.type.nullOr" = "`relations += …` in GrammarElement";
        "types.GrammarElement.options.relations.type.nullOr.nonEmptyListOf" = "GrammarElementRelation";
        "types.GrammarElement.options.tag.type" = "RequirementType";
        "types.GrammarElement.options.viewStyle.type" = "unset is null, not missing";
        "types.GrammarElement.options.viewStyle.type.nullOr" = "'(Plain|Simple|Inline|Narrative|Table|Zebra)' -> ['Plain', 'Simple', 'Inline', 'Narrative', 'Table', 'Zebra']";
        "types.GrammarElementField.multipleChoice.type" = "GrammarElementFieldMultipleChoice";
        "types.GrammarElementField.singleChoice.type" = "GrammarElementFieldSingleChoice";
        "types.GrammarElementField.string.type" = "GrammarElementFieldString";
        "types.GrammarElementField.tag.type" = "GrammarElementFieldTag";
        "types.GrammarElementFieldMultipleChoice.options.choices.type" = "`choices = …` then `choices *= …` in GrammarElementFieldMultipleChoice; the separator rule's own text is suppressed out of the surface, so the ', ' join is the encoder's";
        "types.GrammarElementFieldMultipleChoice.options.choices.type.nonEmptyListOf" = "ChoiceOption";
        "types.GrammarElementFieldMultipleChoice.options.humanTitle.type" = "unset is null, not missing";
        "types.GrammarElementFieldMultipleChoice.options.humanTitle.type.nullOr" = "SingleLineString";
        "types.GrammarElementFieldMultipleChoice.options.required.type" = "BooleanChoice";
        "types.GrammarElementFieldMultipleChoice.options.title.type" = "FieldName";
        "types.GrammarElementFieldSingleChoice.options.choices.type" = "`choices = …` then `choices *= …` in GrammarElementFieldSingleChoice; the separator rule's own text is suppressed out of the surface, so the ', ' join is the encoder's";
        "types.GrammarElementFieldSingleChoice.options.choices.type.nonEmptyListOf" = "ChoiceOption";
        "types.GrammarElementFieldSingleChoice.options.humanTitle.type" = "unset is null, not missing";
        "types.GrammarElementFieldSingleChoice.options.humanTitle.type.nullOr" = "SingleLineString";
        "types.GrammarElementFieldSingleChoice.options.required.type" = "BooleanChoice";
        "types.GrammarElementFieldSingleChoice.options.title.type" = "FieldName";
        "types.GrammarElementFieldString.options.humanTitle.type" = "unset is null, not missing";
        "types.GrammarElementFieldString.options.humanTitle.type.nullOr" = "SingleLineString";
        "types.GrammarElementFieldString.options.required.type" = "BooleanChoice";
        "types.GrammarElementFieldString.options.title.type" = "FieldName";
        "types.GrammarElementFieldTag.options.humanTitle.type" = "unset is null, not missing";
        "types.GrammarElementFieldTag.options.humanTitle.type.nullOr" = "SingleLineString";
        "types.GrammarElementFieldTag.options.required.type" = "BooleanChoice";
        "types.GrammarElementFieldTag.options.title.type" = "FieldName";
        "types.GrammarElementRelation.child.type" = "GrammarElementRelationChild";
        "types.GrammarElementRelation.file.type" = "GrammarElementRelationFile";
        "types.GrammarElementRelation.parent.type" = "GrammarElementRelationParent";
        "types.GrammarElementRelationChild.options.reverseRole.type" = "unset is null, not missing";
        "types.GrammarElementRelationChild.options.reverseRole.type.nullOr" = "'.+' constrains nothing but emptiness";
        "types.GrammarElementRelationChild.options.role.type" = "unset is null, not missing";
        "types.GrammarElementRelationChild.options.role.type.nullOr" = "'.+' constrains nothing but emptiness";
        "types.GrammarElementRelationChild.options.type.type" = "'Child' -> ['Child']";
        "types.GrammarElementRelationFile.options.role.type" = "unset is null, not missing";
        "types.GrammarElementRelationFile.options.role.type.nullOr" = "'.+' constrains nothing but emptiness";
        "types.GrammarElementRelationFile.options.type.type" = "'File' -> ['File']";
        "types.GrammarElementRelationParent.options.reverseRole.type" = "unset is null, not missing";
        "types.GrammarElementRelationParent.options.reverseRole.type.nullOr" = "'.+' constrains nothing but emptiness";
        "types.GrammarElementRelationParent.options.role.type" = "unset is null, not missing";
        "types.GrammarElementRelationParent.options.role.type.nullOr" = "'.+' constrains nothing but emptiness";
        "types.GrammarElementRelationParent.options.type.type" = "'Parent' -> ['Parent']";
        "types.RequirementType" = "RequirementType — a nested group with a quantifier, plus two denied prefixes; enforced denials 'DOCUMENT', 'GRAMMAR'";
        "types.ReservedKeyword" = "'DOCUMENT|GRAMMAR' -> ['DOCUMENT', 'GRAMMAR']";
        "types.SingleLineString" = "SingleLineString — two character classes, plus a denied prefix; enforced denials '>>>\\r?\\n'";
      };
      registry = {
        alias = {
          description = "A rule whose whole body is a reference to a sibling rule.";
          encoder = null;
          kind = "structural";
          rewrite = "unchanged (a rule that is another rule)";
        };
        attrTag = {
          description = "A discriminated union. Left alone: attrTag is already the right shape, and addCheck never fires inside a submodule, so no post-validation guard could replace it.";
          encoder = null;
          kind = "structural";
          rewrite = "unchanged (lib.types.attrTag)";
        };
        boolean = {
          description = "A two-value True/False alternation, in either shape the grammar spells it in: the named OrderedChoice rule BooleanChoice, and the inline regex /(True|False)/ that IS_COMPOSITE carries. The only converter that changes a value's REPRESENTATION rather than narrowing its type, which is why it is the one whose encoder does real work.";
          encoder = "bool";
          kind = "pair";
          rewrite = "lib.types.bool";
        };
        commaList = {
          description = "A separated list: one mandatory element then zero or more of the separator rule. Type unchanged — the grammar demands at least one option and normalized never weakens the decomposition — so the whole content of this pair is the encoder, which joins with ', '. That is the SHARED encoder a MultipleChoice or Tag field value also uses at the document layer; in the grammar surface itself Tag declares no vocabulary, so only the two choice-option lists reach it here.";
          encoder = "list";
          kind = "pair";
          rewrite = "unchanged (lib.types.nonEmptyListOf)";
        };
        decodedOption = {
          description = "A pattern whose faithful spelling is the TOKEN AS WRITTEN and whose normalized value is what that token means. ChoiceOption is the only one: `([\"])[^,]+\\1|[^,()\"]+` is a bare option OR a quoted one, and quoting is not part of the option — it is what buys a literal parenthesis past the unquoted branch. So the normalized value is the option itself, and the encode half puts the quotes back. That half is `emit.nix`'s `choiceOption`, deliberately: `GrammarElementFieldSingleChoice.get_unprocessed_options` decides WHEN to quote, and it lives in strictdoc's WRITER, not in the grammar this file is derived from. The type here is narrower than the token in one direction (no embedded double quote, which would make the round trip ambiguous) and wider in the other (an unquoted parenthesis is fine, because the encoder quotes it) — which is what a converter pair is.";
          encoder = null;
          kind = "pair";
          rewrite = "lib.types.strMatching, over the DECODED value";
        };
        literalAlternation = {
          description = "An INLINE regex that is a single group of pure literal alternation, e.g. VIEW_STYLE's /(Plain|Simple|Inline|Narrative|Table|Zebra)/. Exact, not a widening: builtins.match anchors, so the pattern already accepted exactly this set.";
          encoder = "enum";
          kind = "pair";
          rewrite = "lib.types.enum";
        };
        namedChoice = {
          description = "A named rule whose literal vocabulary the decomposition read off the grammar STRUCTURE (an OrderedChoice of StrMatch children, or a bare StrMatch) rather than off a regex, and recorded as `literals`. Same rewrite as literalAlternation, kept a separate name because it is a separate access path and the two disagreeing is a bug worth being able to see.";
          encoder = "enum";
          kind = "pair";
          rewrite = "lib.types.enum";
        };
        oneOrMore = {
          description = "A `+=` repetition. Already nonEmptyListOf as decomposed; classified so that a list is never left unaccounted for, and so that a future repetition shape has to be classified rather than inherited.";
          encoder = null;
          kind = "pair";
          rewrite = "unchanged (lib.types.nonEmptyListOf)";
        };
        optionalGroup = {
          description = "An optional group in the grammar. The content of this pair is that the option carries `default = null` — without which an unset optional would be a missing-value error instead of an omitted line, and the emitter's `or null` reads would never see it. `decompose.py` gives every optional that default as it builds the declaration, so a nullOr without one cannot be built at all rather than merely being rejected.";
          encoder = null;
          kind = "pair";
          rewrite = "unchanged (lib.types.nullOr, default null)";
        };
        regexPreserved = {
          description = "A pattern a human read and decided stays a regex check — a character class, a quantifier or a nested group, none of which can become an enum without guessing; or one carrying a denial lifted out of a lookahead, which no enum can express. Registered by (source, ere) pair in PRESERVED_PATTERNS, NOT a fallback: an unregistered pattern is an error, so 'we decided this stays a regex' and 'nobody classified this' stay distinguishable.";
          encoder = null;
          kind = "pair";
          rewrite = "unchanged (the decomposed pattern)";
        };
        ruleReference = {
          description = "A type that is another rule by name. Whatever converter fired on THAT rule applies here — which is how REQUIRED becomes a bool without this file naming REQUIRED.";
          encoder = null;
          kind = "structural";
          rewrite = "unchanged (a reference to a sibling rule)";
        };
        submodule = {
          description = "A record. Left alone; its options are classified individually.";
          encoder = null;
          kind = "structural";
          rewrite = "unchanged (lib.types.submodule)";
        };
        unconstrained = {
          description = "A pattern that constrains nothing but emptiness. An EXPLICIT converter and never a fallback: it is the one that says 'we declared this free text'. `.*` becomes types.str and `.+` becomes types.str plus a non-empty check — exact in both directions, because builtins.match anchors and Nix's `.` matches a newline. nonEmptyStr is deliberately NOT used: it also rejects whitespace-only strings, which the grammar accepts.";
          encoder = "str";
          kind = "pair";
          rewrite = "lib.types.str (non-empty as addCheck when the pattern is `.+`)";
        };
      };
    };
    encoders = {
      bool = b:
        if b
        then "True"
        else "False";
      enum = v: v;
      list = xs: lib.concatStringsSep ", " xs;
      str = s: s;
    };
    meta =
      faithful.meta
      // {
        converterCounts = {
          alias = 1;
          attrTag = 2;
          boolean = 2;
          commaList = 2;
          decodedOption = 1;
          literalAlternation = 1;
          namedChoice = 4;
          oneOrMore = 3;
          optionalGroup = 15;
          regexPreserved = 3;
          ruleReference = 26;
          submodule = 10;
          unconstrained = 7;
        };
        generator = "packages/strictdoc-grammar/extract/normalize.py";
        layer = "normalized";
        nodeCount = 77;
      };
    types = rec {
      BooleanChoice = t.bool;
      ChoiceOption = t.strMatching "[^,\"]+";
      ChoiceOptionXs = ChoiceOption;
      DocumentGrammar = t.submodule {
        options = {
          elements = mkOption {
            default = null;
            description = "`ELEMENTS` of `DocumentGrammar`. Optional; a list. Upstream textx attribute `elements`.";
            type = t.nullOr (t.nonEmptyListOf GrammarElement);
          };
          importFromFile = mkOption {
            default = null;
            description = "`IMPORT_FROM_FILE` of `DocumentGrammar`. Optional; a single value. Upstream textx attribute `import_from_file`.";
            type = t.nullOr (t.addCheck t.str (s: s != ""));
          };
        };
      };
      DocumentGrammarWrapper = t.submodule {
        options = {
          grammar = mkOption {
            description = "an unlabelled production of `DocumentGrammarWrapper`. Mandatory; a single value. Upstream textx attribute `grammar`.";
            type = DocumentGrammar;
          };
        };
      };
      FieldName = patternType {
        deny = [
          "RELATIONS"
        ];
        denyAtLineStart = [
          "UID"
        ];
        ere = "[A-Z]+[A-Za-z0-9_-]*";
        rewrites = [
          "bracket-escaped-hyphen"
          "hoist-negative-lookahead"
          "line-anchored-lookahead-is-positional"
          "line-anchored-lookahead-is-reserved"
        ];
        source = "(?!^UID)(?!^RELATIONS)[A-Z]+[A-Za-z0-9_\\-]*";
      };
      GrammarElement = t.submodule {
        options = {
          fields = mkOption {
            description = "`FIELDS` of `GrammarElement`. Mandatory; a list. Upstream textx attribute `fields`.";
            type = t.nonEmptyListOf GrammarElementField;
          };
          isComposite = mkOption {
            default = null;
            description = "`IS_COMPOSITE` of `GrammarElement`. Optional; a single value. Upstream textx attribute `property_is_composite`.";
            type = t.nullOr t.bool;
          };
          prefix = mkOption {
            default = null;
            description = "`PREFIX` of `GrammarElement`. Optional; a single value. Upstream textx attribute `property_prefix`.";
            type = t.nullOr t.str;
          };
          relations = mkOption {
            default = null;
            description = "`RELATIONS` of `GrammarElement`. Optional; a list. Upstream textx attribute `relations`.";
            type = t.nullOr (t.nonEmptyListOf GrammarElementRelation);
          };
          tag = mkOption {
            description = "`TAG` of `GrammarElement`. Mandatory; a single value. Upstream textx attribute `tag`.";
            type = RequirementType;
          };
          viewStyle = mkOption {
            default = null;
            description = "`VIEW_STYLE` of `GrammarElement`. Optional; a single value. Upstream textx attribute `property_view_style`.";
            type = t.nullOr (t.enum ["Plain" "Simple" "Inline" "Narrative" "Table" "Zebra"]);
          };
        };
      };
      GrammarElementField = t.attrTag {
        multipleChoice = mkOption {
          description = "`GrammarElementFieldMultipleChoice` — one alternative of the `GrammarElementField` union. attrTag, not a record with optional extras: the module system's addCheck predicate never fires inside a submodule, so a structural union is the only one with no hole in it.";
          type = GrammarElementFieldMultipleChoice;
        };
        singleChoice = mkOption {
          description = "`GrammarElementFieldSingleChoice` — one alternative of the `GrammarElementField` union. attrTag, not a record with optional extras: the module system's addCheck predicate never fires inside a submodule, so a structural union is the only one with no hole in it.";
          type = GrammarElementFieldSingleChoice;
        };
        string = mkOption {
          description = "`GrammarElementFieldString` — one alternative of the `GrammarElementField` union. attrTag, not a record with optional extras: the module system's addCheck predicate never fires inside a submodule, so a structural union is the only one with no hole in it.";
          type = GrammarElementFieldString;
        };
        tag = mkOption {
          description = "`GrammarElementFieldTag` — one alternative of the `GrammarElementField` union. attrTag, not a record with optional extras: the module system's addCheck predicate never fires inside a submodule, so a structural union is the only one with no hole in it.";
          type = GrammarElementFieldTag;
        };
      };
      GrammarElementFieldMultipleChoice = t.submodule {
        options = {
          choices = mkOption {
            description = "an unlabelled production of `GrammarElementFieldMultipleChoice`. Mandatory; a list. Upstream textx attribute `options`.";
            type = t.nonEmptyListOf ChoiceOption;
          };
          humanTitle = mkOption {
            default = null;
            description = "`HUMAN_TITLE` of `GrammarElementFieldMultipleChoice`. Optional; a single value. Upstream textx attribute `human_title`.";
            type = t.nullOr SingleLineString;
          };
          required = mkOption {
            description = "`REQUIRED` of `GrammarElementFieldMultipleChoice`. Mandatory; a single value. Upstream textx attribute `required`.";
            type = BooleanChoice;
          };
          title = mkOption {
            description = "`TITLE` of `GrammarElementFieldMultipleChoice`. Mandatory; a single value. Upstream textx attribute `title`.";
            type = FieldName;
          };
        };
      };
      GrammarElementFieldSingleChoice = t.submodule {
        options = {
          choices = mkOption {
            description = "an unlabelled production of `GrammarElementFieldSingleChoice`. Mandatory; a list. Upstream textx attribute `options`.";
            type = t.nonEmptyListOf ChoiceOption;
          };
          humanTitle = mkOption {
            default = null;
            description = "`HUMAN_TITLE` of `GrammarElementFieldSingleChoice`. Optional; a single value. Upstream textx attribute `human_title`.";
            type = t.nullOr SingleLineString;
          };
          required = mkOption {
            description = "`REQUIRED` of `GrammarElementFieldSingleChoice`. Mandatory; a single value. Upstream textx attribute `required`.";
            type = BooleanChoice;
          };
          title = mkOption {
            description = "`TITLE` of `GrammarElementFieldSingleChoice`. Mandatory; a single value. Upstream textx attribute `title`.";
            type = FieldName;
          };
        };
      };
      GrammarElementFieldString = t.submodule {
        options = {
          humanTitle = mkOption {
            default = null;
            description = "`HUMAN_TITLE` of `GrammarElementFieldString`. Optional; a single value. Upstream textx attribute `human_title`.";
            type = t.nullOr SingleLineString;
          };
          required = mkOption {
            description = "`REQUIRED` of `GrammarElementFieldString`. Mandatory; a single value. Upstream textx attribute `required`.";
            type = BooleanChoice;
          };
          title = mkOption {
            description = "`TITLE` of `GrammarElementFieldString`. Mandatory; a single value. Upstream textx attribute `title`.";
            type = FieldName;
          };
        };
      };
      GrammarElementFieldTag = t.submodule {
        options = {
          humanTitle = mkOption {
            default = null;
            description = "`HUMAN_TITLE` of `GrammarElementFieldTag`. Optional; a single value. Upstream textx attribute `human_title`.";
            type = t.nullOr SingleLineString;
          };
          required = mkOption {
            description = "`REQUIRED` of `GrammarElementFieldTag`. Mandatory; a single value. Upstream textx attribute `required`.";
            type = BooleanChoice;
          };
          title = mkOption {
            description = "`TITLE` of `GrammarElementFieldTag`. Mandatory; a single value. Upstream textx attribute `title`.";
            type = FieldName;
          };
        };
      };
      GrammarElementRelation = t.attrTag {
        child = mkOption {
          description = "`GrammarElementRelationChild` — one alternative of the `GrammarElementRelation` union. attrTag, not a record with optional extras: the module system's addCheck predicate never fires inside a submodule, so a structural union is the only one with no hole in it.";
          type = GrammarElementRelationChild;
        };
        file = mkOption {
          description = "`GrammarElementRelationFile` — one alternative of the `GrammarElementRelation` union. attrTag, not a record with optional extras: the module system's addCheck predicate never fires inside a submodule, so a structural union is the only one with no hole in it.";
          type = GrammarElementRelationFile;
        };
        parent = mkOption {
          description = "`GrammarElementRelationParent` — one alternative of the `GrammarElementRelation` union. attrTag, not a record with optional extras: the module system's addCheck predicate never fires inside a submodule, so a structural union is the only one with no hole in it.";
          type = GrammarElementRelationParent;
        };
      };
      GrammarElementRelationChild = t.submodule {
        options = {
          reverseRole = mkOption {
            default = null;
            description = "`REVERSE_ROLE` of `GrammarElementRelationChild`. Optional; a single value. Upstream textx attribute `reverse_relation_role`.";
            type = t.nullOr (t.addCheck t.str (s: s != ""));
          };
          role = mkOption {
            default = null;
            description = "`ROLE` of `GrammarElementRelationChild`. Optional; a single value. Upstream textx attribute `relation_role`.";
            type = t.nullOr (t.addCheck t.str (s: s != ""));
          };
          type = mkOption {
            default = "Child";
            description = "`TYPE` of `GrammarElementRelationChild`. Mandatory; a single value. Upstream textx attribute `relation_type`.";
            type = t.enum ["Child"];
          };
        };
      };
      GrammarElementRelationFile = t.submodule {
        options = {
          role = mkOption {
            default = null;
            description = "`ROLE` of `GrammarElementRelationFile`. Optional; a single value. Upstream textx attribute `relation_role`.";
            type = t.nullOr (t.addCheck t.str (s: s != ""));
          };
          type = mkOption {
            default = "File";
            description = "`TYPE` of `GrammarElementRelationFile`. Mandatory; a single value. Upstream textx attribute `relation_type`.";
            type = t.enum ["File"];
          };
        };
      };
      GrammarElementRelationParent = t.submodule {
        options = {
          reverseRole = mkOption {
            default = null;
            description = "`REVERSE_ROLE` of `GrammarElementRelationParent`. Optional; a single value. Upstream textx attribute `reverse_relation_role`.";
            type = t.nullOr (t.addCheck t.str (s: s != ""));
          };
          role = mkOption {
            default = null;
            description = "`ROLE` of `GrammarElementRelationParent`. Optional; a single value. Upstream textx attribute `relation_role`.";
            type = t.nullOr (t.addCheck t.str (s: s != ""));
          };
          type = mkOption {
            default = "Parent";
            description = "`TYPE` of `GrammarElementRelationParent`. Mandatory; a single value. Upstream textx attribute `relation_type`.";
            type = t.enum ["Parent"];
          };
        };
      };
      RequirementType = patternType {
        deny = [
          "DOCUMENT"
          "GRAMMAR"
        ];
        denyAtLineStart = [];
        denyRule = "ReservedKeyword";
        ere = "[A-Z]+(_[A-Z]+)*";
        rewrites = [
          "negative-lookahead-rule"
        ];
        source = "[A-Z]+(_[A-Z]+)*";
      };
      ReservedKeyword = t.enum ["DOCUMENT" "GRAMMAR"];
      SingleLineString = patternType {
        deny = [
          ">>>\r?\n"
        ];
        denyAtLineStart = [];
        ere = "[^[:space:]][^\r\n]*";
        rewrites = [
          "control-escape-to-literal"
          "hoist-negative-lookahead"
          "shorthand-class-to-posix"
        ];
        source = "(?!>>>\r?\n)\\S[^\\r\\n]*";
      };
    };
  }
