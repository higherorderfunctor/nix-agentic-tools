# cspell:ignore attrpath attrset attrsets arpeggio lookaheads sgra textx nullOr strmatching
"""Build the typed Nix surface from faithful's raw rule records, plus encoders.

Reads ``packages/strictdoc-grammar/lib/faithful.nix`` and writes
``packages/strictdoc-grammar/lib/normalized.nix``.

THE DECOMPOSITION LIVES HERE, not in the faithful surface. ``faithful.nix`` is
the grammar's own production tree with every pattern exactly as upstream spells
it — no types, no dialect rewrite, no lookahead lifted out of anything. Turning
that into Nix types is a transformation, so it happens on this side of the line:
``decompose.py`` spells a rule as a Nix type and names every rewrite it
performed on the way, and this module decides which of those types can be
better than a checked string.

Every converter is a PAIR — a type rewrite (faithful type -> normalized type)
and an encoder (normalized value -> faithful value, on the way to the file).
``IS_COMPOSITE`` is ``strMatching "(True|False)"`` decomposed and ``types.bool``
normalized, so its encoder is ``b: if b then "True" else "False"``.

``decompose.py`` builds every node and calls back here for each one; a converter
returns replacement Nix source or nothing, and a node no converter replaces is
the one the decomposition built. ``converters.applied`` in the generated file is
the complete census: every node of the surface, and the named converter that
claimed it.

FAILS LOUDLY. A shape no converter recognizes is an error, never a fallback to
free text: declaring a value unconstrained is itself a NAMED converter, so "we
decided this is free text" stays distinguishable from "nobody classified this".
An upstream grammar change therefore reddens the update sweep instead of
quietly widening a type. Concretely, every one of these raises:

* a pattern record carrying a key, or a ``rewrites`` entry, this module has not
  been taught (``decompose.py`` learned a trick nobody classified);
* a regex that is neither a literal alternation, nor unconstrained, nor in
  ``PRESERVED_PATTERNS`` — the explicit register of patterns a human read and
  decided stay a regex check;
* a node kind ``decompose.py`` emits that no converter claims;
* a list whose faithful production is neither a ``oneOrMore`` repetition nor
  the mandatory-then-``zeroOrMore`` separated pair;
* a ``^``-anchored lookahead whose enforcement nobody has decided — see
  ``decompose.LINE_ANCHORED_DENIALS``.

To see the error path, point the normalizer at a doctored faithful surface —
change one pattern to something unclassifiable and it exits non-zero naming the
pattern and the path it came from:

    sed 's/"(Plain|Simple|Inline|Narrative|Table|Zebra)"/"[a-f0-9]{32}"/' \\
      packages/strictdoc-grammar/lib/faithful.nix > /tmp/doctored.nix
    normalize.py --input /tmp/doctored.nix --output /dev/null

MEASURED, do not re-derive (see ../docs/implementation-brief.md):

* Convert a pattern to an enum ONLY when it is a single group of pure literal
  alternation. A character class, a quantifier or a nested group stays a regex
  check. Never guess an enum from a pattern that was not fully understood.
* ``ast-grep`` and its ``ast_grep_py`` bindings are both 0.45.1, tree-sitter
  based, and ship a Nix grammar — they read the faithful surface's data back
  out of the file in process, with nothing added.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys
from typing import Sequence

from ast_grep_py import SgRoot

import decompose
import emit_nix
from decompose import Surface
from emit_nix import Raw
from shape import ExtractionError

DEFAULT_INPUT = "packages/strictdoc-grammar/lib/faithful.nix"
DEFAULT_OUTPUT = "packages/strictdoc-grammar/lib/normalized.nix"


class UnrecognizedShape(Exception):
    """Raised when no named converter claims a decomposed node.

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
            "option and normalized never weakens the decomposition — so the "
            "whole content of this pair is the encoder, which joins with ', '. "
            "That is the SHARED encoder a MultipleChoice or Tag field value "
            "also uses at the document layer; in the grammar surface itself "
            "Tag declares no vocabulary, so only the two choice-option lists "
            "reach it here."
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
            "The type here is narrower than the token in one direction (no "
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
            "A named rule whose literal vocabulary the decomposition read off "
            "the grammar STRUCTURE (an OrderedChoice of StrMatch children, or "
            "a bare StrMatch) rather than off a regex, and recorded as "
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
            "A `+=` repetition. Already nonEmptyListOf as decomposed; "
            "classified so that a list is never left unaccounted for, and so "
            "that a future repetition shape has to be classified rather than "
            "inherited."
        ),
    },
    "optionalGroup": {
        "kind": "pair",
        "rewrite": "unchanged (lib.types.nullOr, default null)",
        "encoder": None,
        "description": (
            "An optional group in the grammar. The content of this pair is "
            "that the option carries `default = null` — without which an unset "
            "optional would be a missing-value error instead of an omitted "
            "line, and the emitter's `or null` reads would never see it. "
            "`decompose.py` gives every optional that default as it builds the "
            "declaration, so a nullOr without one cannot be built at all "
            "rather than merely being rejected."
        ),
    },
    "regexPreserved": {
        "kind": "pair",
        "rewrite": "unchanged (the decomposed pattern)",
        "encoder": None,
        "description": (
            "A pattern a human read and decided stays a regex check — a "
            "character class, a quantifier or a nested group, none of which can "
            "become an enum without guessing; or one carrying a denial lifted "
            "out of a lookahead, which no enum can express. Registered by "
            "(source, ere) pair in PRESERVED_PATTERNS, NOT a fallback: an "
            "unregistered pattern is an error, so 'we decided this stays a "
            "regex' and 'nobody classified this' stay distinguishable."
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

# Every rewrite name `decompose.py` can attach to a pattern. An unknown one
# means the decomposition learned a rewrite this module has never seen, and the
# pattern it is attached to has therefore not been classified by anyone.
KNOWN_REWRITES = frozenset(
    {
        "backreference-to-literal",
        "bracket-escaped-hyphen",
        "control-escape-to-literal",
        "hoist-negative-lookahead",
        decompose.POSITIONAL_REWRITE,
        decompose.RESERVED_REWRITE,
        "literal-to-pattern",
        "negative-lookahead-rule",
        "ordered-choice-to-alternation",
        "shorthand-class-to-posix",
    }
)

# Keys a pattern record may carry. `literals` and `denyRule` are optional; the
# rest are mandatory.
#
# The two denial lists are the two halves of one split, and both are consulted
# here only to keep the pattern's faithful spelling. `deny` is enforced by
# `patternType`'s addCheck branch and holds every denial that constrains the
# VALUE — a bare lookahead, and a `^`-anchored one whose word is an alternative
# of nothing. `denyAtLineStart` holds the rest: recorded, deliberately inert,
# and never part of the type. `decompose.py` decides which is which.
PATTERN_KEYS = frozenset(
    {"deny", "denyAtLineStart", "denyRule", "ere", "literals", "rewrites", "source"}
)
PATTERN_REQUIRED_KEYS = frozenset({"deny", "denyAtLineStart", "ere", "rewrites", "source"})

# Patterns that stay regex checks, registered as (upstream source, our ERE) with
# the reason. Keyed on BOTH dialects on purpose: upstream changing the regex and
# `decompose.py` changing how it rewrites one are different regressions, and
# each should stop the sweep.
#
# This register is hand-written, and that is the point — it is the only place a
# human decision about a pattern is recorded, so upstream adding a constrained
# field makes the normalizer red until somebody classifies it. It is NOT a
# grammar-derived vocabulary: no enum, knob or field list is typed here.
PRESERVED_PATTERNS: dict[tuple[str, str], str] = {
    (
        "(?!^UID)(?!^RELATIONS)[A-Z]+[A-Za-z0-9_\\-]*",
        "[A-Z]+[A-Za-z0-9_-]*",
    ): "FieldName — a character class with a quantifier, plus two lifted lookahead groups",
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

# The generated file's `let`, as (name to test for use, binding name, source).
# A binding nothing mentions is DROPPED: a converted node can orphan the helper
# it used, and deadnix fails a commit on an unused `let` binding. A binding name
# of None renders its source as a whole line, which is the only way to spell an
# `inherit`.
PREAMBLE: tuple[tuple[str, str | None, str], ...] = (
    ("t", "t", "lib.types"),
    ("mkOption", None, "inherit (lib) mkOption;"),
    ("patternType", "patternType", decompose.PATTERN_TYPE_SRC),
)


## Reading the faithful surface ##############################################


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
        candidates = child.children() if child.kind() == "binding_set" else [child]
        for candidate in candidates:
            if candidate.kind() != "binding":
                continue
            path = candidate.field("attrpath")
            if path is not None:
                key = path.text()
                found[decode_nix_string(key) if key.startswith('"') else key] = candidate
    return found


def value_of(binding):
    """The expression a binding binds."""
    return binding.field("expression")


_ATOMS = {"true": True, "false": False, "null": None}


def nix_data(node):
    """One Nix DATA expression as a Python value.

    The faithful surface is data all the way down — that is what it means for it
    to carry no types — so this reader is total over it, and anything it meets
    that is not data is an error rather than a string it guessed at.
    """
    kind = node.kind()
    if kind == "attrset_expression":
        return {name: nix_data(value_of(b)) for name, b in bindings_of(node).items()}
    if kind == "list_expression":
        return [
            nix_data(child)
            for child in node.children()
            if child.kind() not in ("[", "]")
        ]
    if kind == "string_expression":
        return decode_nix_string(node.text())
    if kind == "integer_expression":
        return int(node.text())
    if kind == "variable_expression":
        text = node.text()
        if text in _ATOMS:
            return _ATOMS[text]
    raise UnrecognizedShape(
        f"the faithful surface carries a {kind} where data was expected: "
        f"{node.text()[:60]!r}"
    )


def read_faithful(source: str) -> dict:
    """The rule records of a faithful surface, by rule name."""
    root = SgRoot(source, "nix").root()
    attrset = root.find(kind="attrset_expression")
    if attrset is None:
        raise UnrecognizedShape("the faithful surface has no attribute set body")
    top = bindings_of(attrset)
    for required in ("meta", "productions"):
        if required not in top:
            raise UnrecognizedShape(f"the faithful surface has no top-level `{required}`")
    if "types" in top:
        raise UnrecognizedShape(
            "the faithful surface carries a `types` block. Types are a "
            "decomposition and this layer must not have one — regenerate it with "
            "the current extract.py"
        )
    rules = nix_data(value_of(top["productions"]))
    if not rules:
        raise UnrecognizedShape("the faithful surface has no productions")
    return rules


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


def classify_pattern(path: str, record: dict) -> dict[str, object]:
    """Classify one pattern record. Raises when nothing claims it.

    Returns the classification: the converter's name, the Nix source that
    replaces the node (or None to keep it), and a detail for the census.
    """
    unknown = sorted(set(record) - PATTERN_KEYS)
    if unknown:
        raise UnrecognizedShape(
            f"{path}: the pattern record carries key(s) {unknown} that no converter "
            f"has been taught; the decomposition is recording something new"
        )
    missing = sorted(PATTERN_REQUIRED_KEYS - set(record))
    if missing:
        raise UnrecognizedShape(f"{path}: the pattern record is missing {missing}")

    source = record["source"]
    ere = record["ere"]
    deny = record["deny"]
    anchored = record["denyAtLineStart"]
    literals = record.get("literals")

    strange = sorted(set(record["rewrites"]) - KNOWN_REWRITES)
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

    # A lifted lookahead is a constraint no enum can carry, so a pattern that
    # has one keeps its faithful spelling whatever else it looks like — the
    # inert half included, because dropping a record is how a decision stops
    # being visible.
    if deny or anchored:
        why = []
        if deny:
            why.append("enforced denials " + ", ".join(map(repr, deny)))
        if anchored:
            why.append(
                "recorded but not enforced, being alternatives of the rule that "
                "denies them: " + ", ".join(map(repr, anchored))
            )
        return _preserve(path, source, ere, "; ".join(why))

    if literals is not None:
        # The vocabulary came off the grammar STRUCTURE. Cross-check it against
        # the regex: the two access paths disagreeing is a real defect, and the
        # decomposition writing `literals` for a pattern that is not an
        # alternation means one of them is lying about the same rule.
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
        return _vocabulary("namedChoice", literals, source)

    if parsed is not None:
        return _vocabulary("literalAlternation", parsed, source)

    if ere in UNCONSTRAINED_EREs:
        return {
            "converter": "unconstrained",
            "replacement": UNCONSTRAINED_EREs[ere],
            "detail": f"{source!r} constrains nothing but emptiness",
        }

    return _preserve(path, source, ere, None)


def _vocabulary(converter: str, literals: list[str], source: str) -> dict[str, object]:
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
        "detail": reason if not why else f"{reason}; {why}",
    }


def classify_list(
    path: str, rule: str, option: str, multiplicities: Sequence[str]
) -> dict[str, object]:
    """Decide which list shape a repetition came from.

    Read off the assignments in faithful's production rather than off the type,
    because the type has already collapsed both list shapes to nonEmptyListOf
    and the difference between them is exactly what decides whether a separator
    is involved.
    """
    shape = list(multiplicities)
    if shape == ["oneOrMore"]:
        return {"converter": "oneOrMore", "detail": f"`{option} += …` in {rule}"}
    if shape == ["one", "zeroOrMore"]:
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
        f"{shape}, which is neither a `+=` repetition nor a "
        f"mandatory-then-`*=` separated pair"
    )


## The walk ##################################################################


class Normalizer:
    """Classifies every node `decompose.py` builds, collecting the census."""

    def __init__(self, source: str) -> None:
        self.rules = read_faithful(source)
        # path -> converter name, the complete census.
        self.applied: dict[str, str] = {}
        self.details: dict[str, str] = {}
        self.types_text = ""

    def run(self) -> None:
        types = Surface(self.rules, self.classify).types()
        self.types_text = "rec " + emit_nix.render_attrs(types, 1)

    ## the converter seam ----------------------------------------------------

    def classify(self, path: str, node: dict) -> str | None:
        kind = node["kind"]
        if kind == "pattern":
            classification = classify_pattern(path, node["record"])
        elif kind in ("submodule", "attrTag"):
            classification = {"converter": kind}
        elif kind == "nullOr":
            classification = {
                "converter": "optionalGroup",
                "detail": "unset is null, not missing",
            }
        elif kind == "list":
            classification = classify_list(
                path, node["rule"], node["option"], node["multiplicities"]
            )
        elif kind in ("alias", "ruleReference"):
            classification = {"converter": kind, "detail": node["target"]}
        else:
            raise UnrecognizedShape(
                f"{path}: decompose.py built a {kind!r} node, which no converter "
                f"claims. A new node kind has to be classified before it can be "
                f"normalized."
            )
        self.record(path, classification)
        replacement = classification.get("replacement")
        return None if replacement is None else str(replacement)

    def record(self, path: str, classification: dict[str, object]) -> None:
        converter = str(classification["converter"])
        if converter not in CONVERTERS:
            raise UnrecognizedShape(f"{path}: unknown converter {converter!r}")
        if path in self.applied:
            raise UnrecognizedShape(f"{path}: classified twice")
        self.applied[path] = converter
        detail = classification.get("detail")
        if detail:
            self.details[path] = str(detail)

    ## output ---------------------------------------------------------------

    def preamble(self) -> list[tuple[str | None, object]]:
        """The `let` bindings the rendered types actually use."""

        def used(name: str) -> bool:
            return (
                re.search(rf"(?<![\w.-]){re.escape(name)}\b", self.types_text) is not None
            )

        return [
            (name, Raw(src)) for probe, name, src in PREAMBLE if used(probe)
        ]


## Rendering #################################################################

HEADER = """#
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
"""


def render(normalizer: Normalizer) -> str:
    """Render the whole normalized surface."""
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
                "types": Raw(normalizer.types_text),
                "encoders": {name: Raw(ENCODER_SOURCE[name]) for name in sorted(used)},
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
            preamble=normalizer.preamble(),
            header_comment=HEADER,
        )
    )


## Entry point ###############################################################


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="strictdoc-grammar-normalize",
        description="Build the typed .sgra surface from the faithful records, plus encoders.",
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
    except (UnrecognizedShape, ExtractionError) as unrecognized:
        print(f"normalize.py: unrecognized shape\n{unrecognized}", file=sys.stderr)
        sys.exit(2)
