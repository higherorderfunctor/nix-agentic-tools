# cspell:ignore attrpath attrset attrsets arpeggio lookaheads sgra textx nullOr strmatching
"""Normalize the faithful Nix surface into better Nix types, plus encoders.

Reads ``packages/strictdoc-grammar/lib/faithful.nix`` and writes
``packages/strictdoc-grammar/lib/normalized.nix``.

Every converter is a PAIR — a type rewrite (faithful type -> normalized type)
and an encoder (normalized value -> faithful value, on the way to the file).
``IS_COMPOSITE`` is ``strMatching "(True|False)"`` faithfully and ``types.bool``
normalized, so its encoder is ``b: if b then "True" else "False"``.

NORMALIZED IS FAITHFUL WITH NODES REPLACED, not a parallel structure. The
generated file is literally faithful's own ``types`` source text with the
converted nodes spliced out and their rewrites spliced in; everything else —
``productions``, ``meta``, every preserved regex, every description — comes
through unchanged, and the emitted body is ``faithful // { … }``. A node this
file never mentions is byte-for-byte the node the extractor wrote.

FAILS LOUDLY. A shape no converter recognizes is an error, never a fallback to
free text: declaring a value unconstrained is itself a NAMED converter, so "we
decided this is free text" stays distinguishable from "nobody classified this".
An upstream grammar change therefore reddens the update sweep instead of
quietly widening a type. Concretely, every one of these raises:

* a ``patternType`` argument carrying a key, or a ``rewrites`` entry, this
  module has not been taught (the extractor learned a trick nobody classified);
* a regex that is neither a literal alternation, nor unconstrained, nor in
  ``PRESERVED_PATTERNS`` — the explicit register of patterns a human read and
  decided stay a regex check;
* a type expression whose head is not one of the four this surface uses
  (``patternType``, ``t.submodule``, ``t.attrTag``, ``t.nullOr`` /
  ``t.nonEmptyListOf``), or a rule reference to a rule that does not exist;
* an optional option that does not carry ``default = null``;
* a list whose faithful production is neither a ``oneOrMore`` repetition nor
  the mandatory-then-``zeroOrMore`` separated pair.

To see the error path, point the normalizer at a doctored faithful surface —
change one ``ere`` to something unclassifiable and it exits non-zero naming the
pattern and the path it came from:

    sed 's/"(Plain|Simple|Inline|Narrative|Table|Zebra)"/"[a-f0-9]{32}"/' \\
      packages/strictdoc-grammar/lib/faithful.nix > /tmp/doctored.nix
    normalize.py --input /tmp/doctored.nix --output /dev/null

MEASURED, do not re-derive (see ../docs/implementation-brief.md):

* Convert a pattern to an enum ONLY when it is a single group of pure literal
  alternation. A character class, a quantifier or a nested group stays a regex
  check. Never guess an enum from a pattern that was not fully understood.
* ``ast-grep`` is the MATCHER, not a rewriter. A ``fix:`` rule emits one text
  replacement and cannot produce a type declaration *and* an encoder from one
  match, so: match, take the captures, emit both from Python. The owning
  attribute name is reachable by walking up to the enclosing ``binding`` node,
  so the field name is available alongside the pattern.
* ``ast-grep`` and its ``ast_grep_py`` bindings are both 0.45.1, tree-sitter
  based, and ship a Nix grammar — they match and capture over Nix source in
  process with nothing added.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys
from typing import Sequence

from ast_grep_py import SgRoot

import emit_nix
from emit_nix import Raw

DEFAULT_INPUT = "packages/strictdoc-grammar/lib/faithful.nix"
DEFAULT_OUTPUT = "packages/strictdoc-grammar/lib/normalized.nix"


class UnrecognizedShape(Exception):
    """Raised when no named converter claims a faithful node.

    This is the fail-closed condition, and it is deliberately an exception and
    not a warning: an unclassified shape must stop the sweep.
    """


## The converter registry ####################################################
#
# Each entry is one half-described PAIR: `rewrite` is what the type becomes,
# `encoder` names the function in `encoders` that turns a normalized value back
# into the faithful one. `kind = "pair"` is a real converter; `kind =
# "structural"` is a classification that leaves the node alone and exists so
# that every node in the surface is accounted for by name rather than by
# silence.
CONVERTERS: dict[str, dict[str, object]] = {
    "alias": {
        "kind": "structural",
        "rewrite": "unchanged (a rule that is another rule)",
        "encoder": None,
        "description": "A rule whose whole body is a reference to a sibling rule.",
    },
    "attrTag": {
        "kind": "structural",
        "rewrite": "unchanged (lib.types.attrTag)",
        "encoder": None,
        "description": (
            "A discriminated union. Left alone: attrTag is already the right "
            "shape, and addCheck never fires inside a submodule, so no "
            "post-validation guard could replace it."
        ),
    },
    "boolean": {
        "kind": "pair",
        "rewrite": "lib.types.bool",
        "encoder": "bool",
        "description": (
            "A two-value True/False alternation, in either shape the grammar "
            "spells it in: the named OrderedChoice rule BooleanChoice, and the "
            "inline regex /(True|False)/ that IS_COMPOSITE carries. The only "
            "converter that changes a value's REPRESENTATION rather than "
            "narrowing its type, which is why it is the one whose encoder does "
            "real work."
        ),
    },
    "commaList": {
        "kind": "pair",
        "rewrite": "unchanged (lib.types.nonEmptyListOf)",
        "encoder": "list",
        "description": (
            "A separated list: one mandatory element then zero or more of the "
            "separator rule. Type unchanged — the grammar demands at least one "
            "option and normalized never weakens faithful — so the whole "
            "content of this pair is the encoder, which joins with ', '. That "
            "is the SHARED encoder a MultipleChoice or Tag field value also "
            "uses at the document layer; in the grammar surface itself Tag "
            "declares no vocabulary, so only the two choice-option lists reach "
            "it here."
        ),
    },
    "decodedOption": {
        "kind": "pair",
        "rewrite": "lib.types.strMatching, over the DECODED value",
        "encoder": None,
        "description": (
            "A pattern whose faithful spelling is the TOKEN AS WRITTEN and "
            "whose normalized value is what that token means. ChoiceOption is "
            "the only one: `([\"])[^,]+\\1|[^,()\"]+` is a bare option OR a "
            "quoted one, and quoting is not part of the option — it is what "
            "buys a literal parenthesis past the unquoted branch. So the "
            "normalized value is the option itself, and the encode half puts "
            "the quotes back. That half is `emit.nix`'s `choiceOption`, "
            "deliberately: `GrammarElementFieldSingleChoice."
            "get_unprocessed_options` decides WHEN to quote, and it lives in "
            "strictdoc's WRITER, not in the grammar this file is derived from. "
            "The type here is narrower than faithful in one direction (no "
            "embedded double quote, which would make the round trip "
            "ambiguous) and wider in the other (an unquoted parenthesis is "
            "fine, because the encoder quotes it) — which is what a converter "
            "pair is."
        ),
    },
    "literalAlternation": {
        "kind": "pair",
        "rewrite": "lib.types.enum",
        "encoder": "enum",
        "description": (
            "An INLINE regex that is a single group of pure literal "
            "alternation, e.g. VIEW_STYLE's "
            "/(Plain|Simple|Inline|Narrative|Table|Zebra)/. Exact, not a "
            "widening: builtins.match anchors, so the pattern already accepted "
            "exactly this set."
        ),
    },
    "namedChoice": {
        "kind": "pair",
        "rewrite": "lib.types.enum",
        "encoder": "enum",
        "description": (
            "A named rule whose literal vocabulary the extractor read off the "
            "grammar STRUCTURE (an OrderedChoice of StrMatch children, or a "
            "bare StrMatch) rather than off a regex, and recorded as "
            "`literals`. Same rewrite as literalAlternation, kept a separate "
            "name because it is a separate access path and the two disagreeing "
            "is a bug worth being able to see."
        ),
    },
    "oneOrMore": {
        "kind": "pair",
        "rewrite": "unchanged (lib.types.nonEmptyListOf)",
        "encoder": None,
        "description": (
            "A `+=` repetition. Already nonEmptyListOf in faithful; classified "
            "so that a list is never left unaccounted for, and so that a "
            "future repetition shape has to be classified rather than "
            "inherited."
        ),
    },
    "optionalGroup": {
        "kind": "pair",
        "rewrite": "unchanged (lib.types.nullOr, default null)",
        "encoder": None,
        "description": (
            "An optional group in the grammar. Already nullOr in faithful; the "
            "content of this pair is the ASSERTION that the option carries "
            "`default = null`, without which an unset optional would be a "
            "missing-value error instead of an omitted line, and the emitter's "
            "`or null` reads would never see it."
        ),
    },
    "regexPreserved": {
        "kind": "pair",
        "rewrite": "unchanged (the faithful pattern)",
        "encoder": None,
        "description": (
            "A pattern a human read and decided stays a regex check — a "
            "character class, a quantifier or a nested group, none of which can "
            "become an enum without guessing. Registered by (source, ere) pair "
            "in PRESERVED_PATTERNS, NOT a fallback: an unregistered pattern is "
            "an error, so 'we decided this stays a regex' and 'nobody "
            "classified this' stay distinguishable."
        ),
    },
    "ruleReference": {
        "kind": "structural",
        "rewrite": "unchanged (a reference to a sibling rule)",
        "encoder": None,
        "description": (
            "A type that is another rule by name. Whatever converter fired on "
            "THAT rule applies here — which is how REQUIRED becomes a bool "
            "without this file naming REQUIRED."
        ),
    },
    "submodule": {
        "kind": "structural",
        "rewrite": "unchanged (lib.types.submodule)",
        "encoder": None,
        "description": "A record. Left alone; its options are classified individually.",
    },
    "unconstrained": {
        "kind": "pair",
        "rewrite": "lib.types.str (non-empty as addCheck when the pattern is `.+`)",
        "encoder": "str",
        "description": (
            "A pattern that constrains nothing but emptiness. An EXPLICIT "
            "converter and never a fallback: it is the one that says 'we "
            "declared this free text'. `.*` becomes types.str and `.+` becomes "
            "types.str plus a non-empty check — exact in both directions, "
            "because builtins.match anchors and Nix's `.` matches a newline. "
            "nonEmptyStr is deliberately NOT used: it also rejects "
            "whitespace-only strings, which the grammar accepts."
        ),
    },
}

# The Nix source of each encoder, keyed by the name `emit.nix` reads it under.
# Only the encoders whose converter actually fired are emitted, so an encoder in
# the file is evidence a node needed it.
#
# `emit.nix` merges `defaultEncoders // normalized.encoders`, and says so: a
# name shipped here WINS, a name not shipped keeps its local twin. These four
# are therefore the authoritative halves of their pairs, and `choiceOption` —
# the quoting rule, which comes from strictdoc's WRITER and not from the
# grammar — is deliberately left to `emit.nix` rather than duplicated here.
ENCODER_SOURCE: dict[str, str] = {
    "bool": 'b:\n  if b\n  then "True"\n  else "False"',
    "enum": "v: v",
    "list": 'xs: lib.concatStringsSep ", " xs',
    "str": "s: s",
}

# Every rewrite name `extract.py` can attach to a pattern. An unknown one means
# the extractor learned a rewrite this module has never seen, and the pattern it
# is attached to has therefore not been classified by anyone.
KNOWN_REWRITES = frozenset(
    {
        "backreference-to-literal",
        "bracket-escaped-hyphen",
        "control-escape-to-literal",
        "hoist-negative-lookahead",
        "line-anchored-lookahead-is-positional",
        "literal-to-pattern",
        "negative-lookahead-rule",
        "ordered-choice-to-alternation",
        "shorthand-class-to-posix",
    }
)

# Keys a `patternType` argument may carry. `literals` and `denyRule` are
# optional; the rest are mandatory.
#
# `denyAtLineStart` carries the `^`-anchored lookaheads, which constrain WHERE a
# rule may be entered rather than what its value may be, and are therefore
# recorded and not enforced — see extract.py's module docstring. Nothing here
# converts it: it is metadata about the pattern, not part of the type.
PATTERN_KEYS = frozenset(
    {"deny", "denyAtLineStart", "denyRule", "ere", "literals", "rewrites", "source"}
)
PATTERN_REQUIRED_KEYS = frozenset({"deny", "denyAtLineStart", "ere", "rewrites", "source"})

# Patterns that stay regex checks, registered as (upstream source, our ERE) with
# the reason. Keyed on BOTH dialects on purpose: upstream changing the regex and
# extract.py changing how it rewrites one are different regressions, and each
# should stop the sweep.
#
# This register is hand-written, and that is the point — it is the only place a
# human decision about a pattern is recorded, so upstream adding a constrained
# field makes the normalizer red until somebody classifies it. It is NOT a
# grammar-derived vocabulary: no enum, knob or field list is typed here.
PRESERVED_PATTERNS: dict[tuple[str, str], str] = {
    (
        "(?!^UID)(?!^RELATIONS)[A-Z]+[A-Za-z0-9_\\-]*",
        "[A-Z]+[A-Za-z0-9_-]*",
    ): "FieldName — a character class with a quantifier, plus two denied prefixes",
    (
        "[A-Z]+(_[A-Z]+)*",
        "[A-Z]+(_[A-Z]+)*",
    ): "RequirementType — a nested group with a quantifier, plus two denied prefixes",
    (
        "(?!>>>\r?\n)\\S[^\\r\\n]*",
        "[^[:space:]][^\r\n]*",
    ): "SingleLineString — two character classes, plus a denied prefix",
}

# Patterns whose normalized type is the DECODED value rather than the token, as
# (upstream source, our ERE) -> (replacement Nix source, reason). Same keying and
# same hand-written discipline as PRESERVED_PATTERNS; consulted first, because
# deciding what a token MEANS supersedes describing how it is spelled.
DECODED_PATTERNS: dict[tuple[str, str], tuple[str, str]] = {
    (
        '(["])[^,]+\\1|[^,()"]+',
        '(["])[^,]+"|[^,()"]+',
    ): (
        't.strMatching "[^,\\"]+"',
        "ChoiceOption -- the decoded option, not the token. A comma is excluded "
        "in both spellings because the separator is unconditionally ', '; a "
        "double quote is excluded so the encoder's quoting round-trips; a "
        "parenthesis is allowed here and quoted on the way out",
    ),
}

# EREs that constrain nothing but emptiness, and what each becomes. `$` is an
# anchor `builtins.match` already implies, so it changes nothing.
UNCONSTRAINED_EREs: dict[str, str] = {
    ".*": "t.str",
    ".*$": "t.str",
    ".+": 't.addCheck t.str (s: s != "")',
    ".+$": 't.addCheck t.str (s: s != "")',
}

# Regex metacharacters. A branch of an alternation carrying any of these is not
# a literal, and the whole pattern therefore stays a regex check.
_REGEX_META = frozenset(".[]()*+?{}|^$\\")

# The escapes `emit_nix.render_string` produces, inverted.
_UNESCAPE = {"\\": "\\", '"': '"', "n": "\n", "r": "\r", "t": "\t", "$": "$"}


## Nix source helpers ########################################################


def decode_nix_string(text: str) -> str:
    """Decode a double-quoted Nix string literal to its value."""
    if len(text) < 2 or not text.startswith('"') or not text.endswith('"'):
        raise UnrecognizedShape(f"not a double-quoted Nix string: {text[:60]!r}")
    body, out, i = text[1:-1], [], 0
    while i < len(body):
        char = body[i]
        if char != "\\":
            out.append(char)
            i += 1
            continue
        if i + 1 >= len(body):
            raise UnrecognizedShape(f"trailing backslash in {text[:60]!r}")
        escaped = body[i + 1]
        if escaped not in _UNESCAPE:
            raise UnrecognizedShape(f"unknown Nix escape \\{escaped} in {text[:60]!r}")
        out.append(_UNESCAPE[escaped])
        i += 2
    return "".join(out)


def bindings_of(node) -> dict[str, object]:
    """The bindings of an attribute set, by attribute name.

    Handles both shapes tree-sitter produces: bindings gathered under a
    `binding_set`, and bindings sitting directly under the braces.
    """
    found: dict[str, object] = {}
    for child in node.children():
        candidates = (
            child.children() if child.kind() == "binding_set" else [child]
        )
        for candidate in candidates:
            if candidate.kind() != "binding":
                continue
            path = candidate.field("attrpath")
            if path is not None:
                found[path.text()] = candidate
    return found


def value_of(binding):
    """The expression a binding binds."""
    return binding.field("expression")


def unwrap(node):
    """Strip one layer of parentheses, if there is one."""
    if node.kind() != "parenthesized_expression":
        return node
    for child in node.children():
        if child.kind() not in ("(", ")"):
            return child
    raise UnrecognizedShape("empty parenthesized expression")


def apply_parts(node) -> tuple[str, object]:
    """Split an application into its function's source text and its argument."""
    children = [c for c in node.children() if c.kind() not in ("(", ")")]
    if len(children) != 2:
        raise UnrecognizedShape(
            f"expected a one-argument application, got {len(children)} children"
        )
    return children[0].text(), unwrap(children[1])


def string_value(node) -> str:
    """The value of a string-literal expression."""
    return decode_nix_string(node.text())


def string_list(node) -> list[str]:
    """The values of a list of string literals."""
    if node.kind() != "list_expression":
        raise UnrecognizedShape(f"expected a list, got {node.kind()}")
    return [
        string_value(child)
        for child in node.children()
        if child.kind() not in ("[", "]")
    ]


## Pattern analysis ##########################################################


def _outer_group_spans_all(ere: str) -> bool:
    """Whether the pattern is exactly one parenthesised group."""
    if not (ere.startswith("(") and ere.endswith(")")):
        return False
    depth, i = 0, 0
    while i < len(ere):
        char = ere[i]
        if char == "\\":
            i += 2
            continue
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return i == len(ere) - 1
        i += 1
    return False


def literal_alternation(ere: str) -> list[str] | None:
    """The literals of a pure literal alternation, or None if it is not one.

    A single group of literals separated by `|`, and nothing else. A character
    class, a quantifier or a nested group disqualifies the whole pattern — the
    brief is explicit that those stay regex checks rather than being guessed at.
    A pattern with no `|` at all counts, with one literal: that is how a bare
    StrMatch like `Parent` arrives.
    """
    body = ere[1:-1] if _outer_group_spans_all(ere) else ere
    if not body:
        return None
    literals = body.split("|")
    for literal in literals:
        if not literal or any(char in _REGEX_META for char in literal):
            return None
    return literals


def classify_pattern(path: str, arg) -> dict[str, object]:
    """Classify one `patternType { … }` argument. Raises when nothing claims it.

    Returns the classification: the converter's name, the Nix source that
    replaces the node (or None to keep it), and a detail for the census.
    """
    fields = bindings_of(arg)
    unknown = set(fields) - PATTERN_KEYS
    if unknown:
        raise UnrecognizedShape(
            f"{path}: patternType carries key(s) {sorted(unknown)} that no converter "
            f"has been taught; the extractor is recording something new"
        )
    missing = PATTERN_REQUIRED_KEYS - set(fields)
    if missing:
        raise UnrecognizedShape(f"{path}: patternType is missing {sorted(missing)}")

    source = string_value(value_of(fields["source"]))
    ere = string_value(value_of(fields["ere"]))
    deny = string_list(value_of(fields["deny"]))
    rewrites = string_list(value_of(fields["rewrites"]))
    literals = (
        string_list(value_of(fields["literals"])) if "literals" in fields else None
    )

    strange = sorted(set(rewrites) - KNOWN_REWRITES)
    if strange:
        raise UnrecognizedShape(
            f"{path}: pattern carries rewrite(s) {strange} this module has never "
            f"seen, so nothing here has classified what they did to {source!r}"
        )

    decoded = DECODED_PATTERNS.get((source, ere))
    if decoded is not None:
        replacement, reason = decoded
        return {
            "converter": "decodedOption",
            "replacement": replacement,
            "detail": reason,
        }

    parsed = literal_alternation(ere)

    # A denied prefix is a constraint no enum can carry, so the pattern keeps
    # its faithful spelling whatever else it looks like.
    if deny:
        return _preserve(path, source, ere, "denied prefixes " + ", ".join(map(repr, deny)))

    if literals is not None:
        # The vocabulary came off the grammar STRUCTURE. Cross-check it against
        # the regex: the two access paths disagreeing is a real defect, and the
        # extractor writing `literals` for a pattern that is not an alternation
        # means one of them is lying about the same rule.
        if parsed is None:
            raise UnrecognizedShape(
                f"{path}: `literals` {literals} was recorded but the ERE {ere!r} is "
                f"not a literal alternation — the metamodel and the parser tree "
                f"disagree about this rule"
            )
        if parsed != literals:
            raise UnrecognizedShape(
                f"{path}: `literals` {literals} does not match the ERE {ere!r}, "
                f"which spells {parsed}"
            )
        return _vocabulary(path, "namedChoice", literals, source, ere)

    if parsed is not None:
        return _vocabulary(path, "literalAlternation", parsed, source, ere)

    if ere in UNCONSTRAINED_EREs:
        return {
            "converter": "unconstrained",
            "replacement": UNCONSTRAINED_EREs[ere],
            "detail": f"{source!r} constrains nothing but emptiness",
        }

    return _preserve(path, source, ere, None)


def _vocabulary(
    path: str, converter: str, literals: list[str], source: str, ere: str
) -> dict[str, object]:
    """A literal vocabulary: types.bool for True/False, types.enum otherwise."""
    if literals == ["True", "False"]:
        return {
            "converter": "boolean",
            "replacement": "t.bool",
            "detail": f"{source!r} via {converter}",
        }
    rendered = " ".join(emit_nix.render_string(literal) for literal in literals)
    return {
        "converter": converter,
        "replacement": f"t.enum [{rendered}]",
        "detail": f"{source!r} -> {literals}",
    }


def _preserve(path: str, source: str, ere: str, why: str | None) -> dict[str, object]:
    """Keep a pattern as a regex check — but only a REGISTERED one."""
    reason = PRESERVED_PATTERNS.get((source, ere))
    if reason is None:
        raise UnrecognizedShape(
            f"{path}: no converter claims the pattern {source!r} (as ERE {ere!r}).\n"
            f"  It is not a literal alternation, not unconstrained, and not in "
            f"PRESERVED_PATTERNS.\n"
            f"  Classify it: give it a converter, or register it as a regex check "
            f"with the reason it stays one. Do not widen it to free text — that is "
            f"what the `unconstrained` converter is for, and it says something "
            f"different."
        )
    return {
        "converter": "regexPreserved",
        "replacement": None,
        "detail": reason if why is None else f"{reason}; {why}",
    }


## Productions ###############################################################


def option_multiplicities(production, option: str) -> list[str]:
    """The multiplicities of every assignment to `option`, in source order.

    Read out of faithful's `productions` rather than off the type, because the
    type has already collapsed both list shapes to nonEmptyListOf and the
    difference between them is exactly what decides whether a separator is
    involved.
    """
    hits = []
    for binding in production.find_all(kind="binding"):
        path = binding.field("attrpath")
        if path is None or path.text() != "option":
            continue
        if string_value(value_of(binding)) != option:
            continue
        item = binding.parent()
        while item is not None and item.kind() not in (
            "attrset_expression",
            "rec_attrset_expression",
        ):
            item = item.parent()
        if item is None:
            continue
        fields = bindings_of(item)
        if "multiplicity" not in fields:
            continue
        hits.append(
            (binding.range().start.index, string_value(value_of(fields["multiplicity"])))
        )
    return [multiplicity for _, multiplicity in sorted(hits)]


## The walk ##################################################################


class Normalizer:
    """Classifies every node of the faithful surface, collecting replacements."""

    def __init__(self, source: str) -> None:
        self.source = source
        self.root = SgRoot(source, "nix").root()
        top = bindings_of(self._top_attrset())
        for required in ("meta", "productions", "types"):
            if required not in top:
                raise UnrecognizedShape(
                    f"the faithful surface has no top-level `{required}`"
                )
        self.types_node = value_of(top["types"])
        self.productions = bindings_of(value_of(top["productions"]))
        self.rules = bindings_of(self.types_node)
        # (start, end, replacement) in `source` coordinates.
        self.replacements: list[tuple[int, int, str]] = []
        # path -> converter name, the complete census.
        self.applied: dict[str, str] = {}
        self.details: dict[str, str] = {}

    def _top_attrset(self):
        node = self.root
        for kind in ("function_expression", "let_expression"):
            found = node.find(kind=kind)
            if found is not None:
                node = found
        attrset = node.find(kind="attrset_expression")
        if attrset is None:
            raise UnrecognizedShape("the faithful surface has no attribute set body")
        return attrset

    ## recording ------------------------------------------------------------

    def record(self, path: str, classification: dict[str, object], node=None) -> None:
        converter = str(classification["converter"])
        if converter not in CONVERTERS:
            raise UnrecognizedShape(f"{path}: unknown converter {converter!r}")
        if path in self.applied:
            raise UnrecognizedShape(f"{path}: classified twice")
        self.applied[path] = converter
        detail = classification.get("detail")
        if detail:
            self.details[path] = str(detail)
        replacement = classification.get("replacement")
        if replacement is not None:
            if node is None:
                raise UnrecognizedShape(f"{path}: a replacement needs a node to splice")
            # A rewrite that is a single atom swallows the parentheses the
            # pattern needed, because `t.nullOr (t.bool)` is a statix warning
            # and `t.nullOr t.bool` is the same type. A rewrite that applies
            # anything keeps them, because there they are load-bearing.
            span_node = node
            if " " not in str(replacement):
                parent = node.parent()
                if parent is not None and parent.kind() == "parenthesized_expression":
                    span_node = parent
            span = span_node.range()
            self.replacements.append(
                (span.start.index, span.end.index, str(replacement))
            )

    ## walking ---------------------------------------------------------------

    def run(self) -> None:
        for name, binding in self.rules.items():
            self.walk_type(f"types.{name}", value_of(binding), rule=name)

    def walk_type(self, path: str, node, *, rule: str, option: str | None = None) -> None:
        """Classify one type expression, and everything under it."""
        kind = node.kind()

        if kind == "variable_expression":
            target = node.text()
            if target not in self.rules:
                raise UnrecognizedShape(
                    f"{path}: reference to `{target}`, which is not a rule of this "
                    f"surface"
                )
            converter = "alias" if path.count(".") == 1 else "ruleReference"
            self.record(path, {"converter": converter, "detail": target})
            return

        if kind != "apply_expression":
            raise UnrecognizedShape(
                f"{path}: expected a type expression, got a {kind}: "
                f"{node.text()[:60]!r}"
            )

        head, arg = apply_parts(node)

        if head == "patternType":
            self.record(path, classify_pattern(path, arg), node)
            return

        if head == "t.submodule":
            self.record(path, {"converter": "submodule"})
            fields = bindings_of(arg)
            if set(fields) != {"options"}:
                raise UnrecognizedShape(
                    f"{path}: a submodule carrying {sorted(fields)} rather than only "
                    f"`options`"
                )
            for name, binding in bindings_of(value_of(fields["options"])).items():
                self.walk_option(f"{path}.options.{name}", value_of(binding), rule=rule, option=name)
            return

        if head == "t.attrTag":
            self.record(path, {"converter": "attrTag"})
            for name, binding in bindings_of(arg).items():
                self.walk_option(f"{path}.{name}", value_of(binding), rule=rule, option=name)
            return

        if head == "t.nullOr":
            self.record(
                path,
                {"converter": "optionalGroup", "detail": "unset is null, not missing"},
            )
            self.walk_type(f"{path}.nullOr", arg, rule=rule, option=option)
            return

        if head == "t.nonEmptyListOf":
            self.record(path, self.classify_list(path, rule, option), )
            self.walk_type(f"{path}.nonEmptyListOf", arg, rule=rule, option=option)
            return

        raise UnrecognizedShape(
            f"{path}: no converter claims the type {node.text()[:60]!r}, whose head "
            f"is `{head}`. The four this surface uses are patternType, "
            f"t.submodule, t.attrTag and t.nullOr / t.nonEmptyListOf; a fifth has "
            f"to be classified before it can be normalized."
        )

    def classify_list(self, path: str, rule: str, option: str | None) -> dict[str, object]:
        """Decide which list shape a nonEmptyListOf came from."""
        if option is None or rule not in self.productions:
            raise UnrecognizedShape(
                f"{path}: a list with no production to read its shape out of"
            )
        multiplicities = option_multiplicities(value_of(self.productions[rule]), option)
        if multiplicities == ["oneOrMore"]:
            return {"converter": "oneOrMore", "detail": f"`{option} += …` in {rule}"}
        if multiplicities == ["one", "zeroOrMore"]:
            return {
                "converter": "commaList",
                "detail": (
                    f"`{option} = …` then `{option} *= …` in {rule}; the separator "
                    f"rule's own text is suppressed out of the surface, so the "
                    f"', ' join is the encoder's"
                ),
            }
        raise UnrecognizedShape(
            f"{path}: the production for `{option}` in {rule} has multiplicities "
            f"{multiplicities}, which is neither a `+=` repetition nor a "
            f"mandatory-then-`*=` separated pair"
        )

    def walk_option(self, path: str, node, *, rule: str, option: str) -> None:
        """Classify one `mkOption { … }` declaration."""
        if node.kind() != "apply_expression":
            raise UnrecognizedShape(f"{path}: expected mkOption, got a {node.kind()}")
        head, arg = apply_parts(node)
        if head != "mkOption":
            raise UnrecognizedShape(f"{path}: expected mkOption, got `{head}`")
        fields = bindings_of(arg)
        unknown = set(fields) - {"default", "description", "type"}
        if unknown:
            raise UnrecognizedShape(
                f"{path}: mkOption carries {sorted(unknown)}, which nothing here "
                f"knows how to normalize"
            )
        if "type" not in fields:
            raise UnrecognizedShape(f"{path}: mkOption with no type")

        type_node = value_of(fields["type"])
        type_path = f"{path}.type"
        # The optionalGroup pair's content is this assertion: an optional whose
        # default is not null is a missing-value error at evaluation, not an
        # omitted line at emission.
        if type_node.kind() == "apply_expression":
            head, _ = apply_parts(type_node)
            if head == "t.nullOr":
                default = fields.get("default")
                if default is None or value_of(default).text() != "null":
                    raise UnrecognizedShape(
                        f"{path}: nullOr without `default = null`, so an unset "
                        f"optional would not reach the emitter as null"
                    )
        self.walk_type(type_path, type_node, rule=rule, option=option)

    ## output ---------------------------------------------------------------

    def normalized_types(self) -> str:
        """Faithful's `types` source with the converted nodes spliced out."""
        span = self.types_node.range()
        start, end = span.start.index, span.end.index
        text = self.source[start:end]
        for from_index, to_index, replacement in sorted(self.replacements, reverse=True):
            if not start <= from_index < to_index <= end:
                raise UnrecognizedShape("a replacement fell outside the types block")
            text = text[: from_index - start] + replacement + text[to_index - start :]
        return text

    def preamble(self, types_text: str) -> list[tuple[str | None, object]]:
        """Faithful's own `let` bindings, verbatim, minus any the splice orphaned.

        Copied rather than reimplemented: the preserved patterns must keep
        exactly the semantics the extractor gave them, and the only way to be
        sure of that is to carry the same helper source.

        A binding no longer mentioned is dropped, because a converted node can
        orphan the helper it used and deadnix fails a commit on an unused
        `let` binding. An `inherit … ;` is carried across verbatim, name and
        all — `emit_nix.render_let` renders a `None` name as a whole line.
        """
        let_expression = self.root.find(kind="let_expression")
        if let_expression is None:
            raise UnrecognizedShape("the faithful surface has no `let`")

        def used(name: str) -> bool:
            return re.search(rf"(?<![\w.-]){re.escape(name)}\b", types_text) is not None

        kept: list[tuple[str | None, object]] = []
        for group in let_expression.children():
            children = (
                group.children()
                if group.kind() == "binding_set"
                else [group]
            )
            for child in children:
                if child.kind() == "binding":
                    name = child.field("attrpath").text()
                    if used(name):
                        kept.append((name, Raw(value_of(child).text())))
                elif child.kind() == "inherit_from":
                    names = [
                        attrs.text()
                        for attrs in child.children()
                        if attrs.kind() == "inherited_attrs"
                    ]
                    if any(used(name) for name in " ".join(names).split()):
                        kept.append((None, Raw(child.text())))
        return kept


## Rendering #################################################################

HEADER = """#
# Written by packages/strictdoc-grammar/extract/normalize.py from ./faithful.nix.
#
# NORMALIZED is faithful with specific nodes replaced — deep-merge in spirit and
# in fact. The body below is `faithful // { … }`, and the `types` block is
# faithful's own source text with the converted nodes spliced out. Anything this
# file does not mention is the node the extractor wrote, byte for byte.
#
# Every converter is a PAIR: a type rewrite (faithful type -> normalized type)
# and an encoder (normalized value -> faithful value, on the way to the file).
# `IS_COMPOSITE` is `strMatching "(True|False)"` faithfully and `types.bool`
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
"""


def render(normalizer: Normalizer) -> str:
    """Render the whole normalized surface."""
    types_text = normalizer.normalized_types()
    used = {
        str(CONVERTERS[converter]["encoder"])
        for converter in normalizer.applied.values()
        if CONVERTERS[converter]["encoder"] is not None
    }
    counts: dict[str, int] = {}
    for converter in normalizer.applied.values():
        counts[converter] = counts.get(converter, 0) + 1

    registry = {
        name: {
            "description": str(entry["description"]),
            "encoder": entry["encoder"],
            "kind": str(entry["kind"]),
            "rewrite": str(entry["rewrite"]),
        }
        for name, entry in CONVERTERS.items()
        if name in counts
    }

    body = Raw(
        "faithful\n// "
        + emit_nix.render_attrs(
            {
                "types": Raw(types_text),
                "encoders": {
                    name: Raw(ENCODER_SOURCE[name]) for name in sorted(used)
                },
                "converters": {
                    "applied": dict(sorted(normalizer.applied.items())),
                    "detail": dict(sorted(normalizer.details.items())),
                    "registry": registry,
                },
                "meta": Raw(
                    "faithful.meta\n// "
                    + emit_nix.render_attrs(
                        {
                            "converterCounts": dict(sorted(counts.items())),
                            "generator": "packages/strictdoc-grammar/extract/normalize.py",
                            "layer": "normalized",
                            "nodeCount": len(normalizer.applied),
                        },
                        1,
                    )
                ),
            }
        )
    )
    return emit_nix.format_nix(
        emit_nix.render_file(
            body,
            "{\n  lib,\n  faithful,\n  ...\n}",
            preamble=normalizer.preamble(types_text),
            header_comment=HEADER,
        )
    )


## Entry point ###############################################################


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="strictdoc-grammar-normalize",
        description="Rewrite the faithful .sgra surface into normalized types plus encoders.",
    )
    parser.add_argument(
        "--input",
        default=DEFAULT_INPUT,
        help="path of the faithful surface to read (default: %(default)s)",
    )
    parser.add_argument(
        "--output",
        default=DEFAULT_OUTPUT,
        help="path of the normalized surface to write (default: %(default)s)",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="regenerate and diff instead of writing; non-zero exit on drift",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    source = pathlib.Path(args.input).read_text(encoding="utf-8")
    normalizer = Normalizer(source)
    normalizer.run()
    return emit_nix.write_or_check(args.output, render(normalizer), args.check)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except UnrecognizedShape as unrecognized:
        print(f"normalize.py: unrecognized shape\n{unrecognized}", file=sys.stderr)
        sys.exit(2)
