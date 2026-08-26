# cspell:ignore asgn oneormore zeroormore lookaheads
"""Faithful extraction of StrictDoc's ``.sgra`` grammar into a Nix surface.

Writes ``packages/strictdoc-grammar/lib/faithful.nix``. Runs at generation time,
outside Nix; Nix never parses StrictDoc during evaluation.

MEASURED, do not re-derive (see ../docs/implementation-brief.md):

* StrictDoc assembles its own grammar into a plain string, byte-identical
  between 0.28.2 and 0.28.3::

      from textx import metamodel_from_str
      from strictdoc.backend.sdoc.grammar.grammar_builder import (
          SDocGrammarBuilder as B,
      )

      mm = metamodel_from_str(B.create_grammar_grammar())

* BOTH access paths are needed. The metamodel (``mm[rule]._tx_attrs``,
  ``_tx_inh_by``, ``_tx_type``) yields the skeleton; walking from
  ``DocumentGrammarWrapper`` reaches 25 of 43 rules and the rest are
  document-side. The parser tree (``mm[rule]._tx_peg_rule``, walked as arpeggio
  ``Optional`` / ``RegExMatch`` / ``StrMatch`` / ``OrderedChoice`` nodes) is
  REQUIRED on top, because the metamodel reports every attribute as ``mult=1``
  regardless of optionality and flattens value vocabularies to ``STRING``.
* Literal sets arrive in TWO shapes and both must be handled: named rules
  (``BooleanChoice`` is an ``OrderedChoice`` of ``StrMatch`` children) and
  inline regex alternations (``IS_COMPOSITE`` is ``/(True|False)/``).

Faithful means faithful: this module classifies nothing. A value constrained by
a regex comes out as a string carrying that regex. Turning a pure literal
alternation into an enum is ``normalize.py``'s job.

── Two things that are NOT re-derivation and had to be decided here ──────────

**Attribute names come from the grammar's own literal keys.** ``'    ROLE: '``
is in the production immediately before the assignment it labels, so ``role``
is extracted, not typed by a person — and it is the name a ``.sgra`` file
actually carries, which the textx attribute name (``relation_role``) is not.
Where a production has no key (``SingleChoice(a, b)`` labels its options with a
parenthesis), the textx attribute name is the fallback. Both spellings are kept
in ``productions`` so nothing is lost.

**Nix's regex engine is POSIX ERE and StrictDoc's patterns are Python's.**
``builtins.match`` rejects lookahead, ``\\S`` and backreferences outright —
MEASURED — so a literal transcription of ``FieldName``'s pattern would produce a
type that throws the moment anything is checked against it. Every pattern
therefore carries BOTH spellings: ``source`` is upstream's, verbatim and
authoritative, and ``ere`` is a mechanical dialect rewrite whose every step is
named in ``rewrites``. The rewrites are exact, never widening: a leading
``(?!DOCUMENT)`` becomes an explicit ``deny`` prefix rather than being dropped,
and a construct no named rewrite claims is an ERROR, not a fallback to free
text.

**A ``^``-anchored lookahead is POSITIONAL, not a value constraint**, and it is
recorded rather than enforced. arpeggio compiles every ``RegExMatch`` with
``re.MULTILINE`` and applies it with ``regex.match(input, pos)``, so ``^`` holds
only where ``pos`` is a line start. ``FieldName`` is
``/(?!^UID)(?!^RELATIONS)[A-Z]+[A-Za-z0-9_\\-]*/`` and is always entered
mid-line, immediately after the literal ``'  - TITLE: '`` — so a field titled
``UID`` parses, which is exactly what this repository's own
``docs/sdoc/grammar.sgra`` does. Hoisting those two into ``deny`` produced a
type that rejected a string StrictDoc accepts. They now land in
``denyAtLineStart``, under the named rewrite
``line-anchored-lookahead-is-positional``: recognized and written down, but not
a constraint the value alone can violate. ``RequirementType``'s
``!ReservedKeyword`` is the other shape and stays a real ``deny`` — it is a
lookahead over the value itself, with no anchor.
"""

from __future__ import annotations

import argparse
import hashlib
import sys
from typing import Any, Sequence

import emit_nix
from emit_nix import Raw

DEFAULT_OUTPUT = "packages/strictdoc-grammar/lib/faithful.nix"

# Where the walk starts. Everything the `.sgra` grammar can express is reachable
# from here; what is not reachable is document-side and belongs to `.sdoc`.
ROOT_RULE = "DocumentGrammarWrapper"

# Names bound in the generated file's `let`. A rule that collided with one would
# be shadowed inside `types`, so the collision is asserted away rather than
# hoped about.
PREAMBLE_NAMES = ("t", "mkOption", "patternType")

# textx spells a multiplicity by naming the synthetic assignment rule.
_ASSIGNMENT_MULTIPLICITY = {
    "__asgn_plain": "one",
    "__asgn_bool": "one",
    "__asgn_oneormore": "oneOrMore",
    "__asgn_zeroormore": "zeroOrMore",
    "__asgn_list": "zeroOrMore",
}

# Characters an ERE gives a special meaning, for escaping a literal into one.
_ERE_SPECIAL = set(r".^$*+?()[]{}|\\")

# Escapes whose meaning is identical in both dialects and can be passed through.
_ERE_SAFE_ESCAPES = set(r".^$*+?()[]{}|\\")

# Python shorthand classes, spelled as POSIX bracket expressions. The values are
# the *inside* of a bracket expression, so they compose in both positions.
_SHORTHAND_INSIDE = {
    "d": "0-9",
    "w": "0-9A-Za-z_",
    "s": "[:space:]",
}
_SHORTHAND_NEGATED = {"D": "d", "W": "w", "S": "s"}

# Escapes that stand for a control character. ERE has no such escape, so the
# character itself is emitted.
_CONTROL_ESCAPES = {"n": "\n", "r": "\r", "t": "\t"}


class ExtractionError(Exception):
    """Raised when the grammar has a shape this extractor does not recognize.

    Deliberately fatal. An unrecognized shape must redden a regeneration rather
    than quietly produce a surface that is missing part of the grammar.
    """


# ─── the ERE dialect compiler ────────────────────────────────────────────────


def _capture_group_sources(pattern: str) -> dict[int, str]:
    """Map each capturing group's number to its inner source text."""
    sources: dict[int, str] = {}
    stack: list[tuple[int, int]] = []
    number = 0
    index = 0
    in_class = False
    while index < len(pattern):
        char = pattern[index]
        if char == "\\":
            index += 2
            continue
        if in_class:
            if char == "]":
                in_class = False
            index += 1
            continue
        if char == "[":
            in_class = True
            index += 1
            continue
        if char == "(":
            if pattern[index + 1 : index + 2] == "?":
                stack.append((-1, index))
            else:
                number += 1
                stack.append((number, index + 1))
            index += 1
            continue
        if char == ")":
            if not stack:
                raise ExtractionError(f"unbalanced ')' in pattern {pattern!r}")
            group_number, start = stack.pop()
            if group_number > 0:
                sources[group_number] = pattern[start:index]
            index += 1
            continue
        index += 1
    if stack:
        raise ExtractionError(f"unbalanced '(' in pattern {pattern!r}")
    return sources


def _single_literal_of(group_source: str) -> str:
    """The one character a group can match, or an error.

    Only ever asked of a backreference target. ``(["])`` is the whole reason
    this exists: it is a one-member bracket expression, so the reference is an
    exact literal and substituting it changes nothing.
    """
    if len(group_source) == 1 and group_source not in _ERE_SPECIAL:
        return group_source
    if (
        len(group_source) == 3
        and group_source[0] == "["
        and group_source[2] == "]"
        and group_source[1] not in "^]"
    ):
        return group_source[1]
    raise ExtractionError(
        f"backreference target {group_source!r} is not a single literal; no named "
        "rewrite claims it"
    )


def _hoist_lookaheads(pattern: str) -> tuple[str, list[str], bool]:
    """Split leading ``(?!…)`` groups off the front of ``pattern``."""
    denials: list[str] = []
    hoisted = False
    while pattern.startswith("(?!"):
        # depth starts at 1: the `(` of `(?!` is already consumed.
        depth = 1
        index = 3
        in_class = False
        end = -1
        while index < len(pattern):
            char = pattern[index]
            if char == "\\":
                index += 2
                continue
            if in_class:
                if char == "]":
                    in_class = False
            elif char == "[":
                in_class = True
            elif char == "(":
                depth += 1
            elif char == ")":
                depth -= 1
                if depth == 0:
                    end = index
                    break
            index += 1
        if end < 0:
            raise ExtractionError(f"unterminated lookahead in pattern {pattern!r}")
        denials.append(pattern[3:end])
        pattern = pattern[end + 1 :]
        hoisted = True
    if hoisted and _has_top_level_alternation(pattern):
        raise ExtractionError(
            "a hoisted lookahead in front of a top-level alternation would change "
            f"which branch it guards: {pattern!r}"
        )
    if "(?" in pattern:
        raise ExtractionError(
            f"pattern {pattern!r} carries an inline group Nix's regex engine "
            "cannot express, and it is not at the front to be hoisted"
        )
    return pattern, denials, hoisted


def _has_top_level_alternation(pattern: str) -> bool:
    depth = 0
    in_class = False
    index = 0
    while index < len(pattern):
        char = pattern[index]
        if char == "\\":
            index += 2
            continue
        if in_class:
            if char == "]":
                in_class = False
        elif char == "[":
            in_class = True
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
        elif char == "|" and depth == 0:
            return True
        index += 1
    return False


def _rewrite_body(pattern: str, groups: dict[int, str], rewrites: set[str]) -> str:
    """Rewrite one lookahead-free pattern into POSIX ERE."""
    out: list[str] = []
    index = 0
    in_class = False
    while index < len(pattern):
        char = pattern[index]
        if char == "\\":
            escape = pattern[index + 1 : index + 2]
            if not escape:
                raise ExtractionError(f"trailing backslash in pattern {pattern!r}")
            index += 2
            if escape in _CONTROL_ESCAPES:
                out.append(_CONTROL_ESCAPES[escape])
                rewrites.add("control-escape-to-literal")
                continue
            if escape in _SHORTHAND_INSIDE:
                inside = _SHORTHAND_INSIDE[escape]
                out.append(inside if in_class else f"[{inside}]")
                rewrites.add("shorthand-class-to-posix")
                continue
            if escape in _SHORTHAND_NEGATED:
                if in_class:
                    raise ExtractionError(
                        f"negated shorthand \\{escape} inside a bracket expression "
                        f"has no POSIX spelling: {pattern!r}"
                    )
                out.append(f"[^{_SHORTHAND_INSIDE[_SHORTHAND_NEGATED[escape]]}]")
                rewrites.add("shorthand-class-to-posix")
                continue
            if escape == "-":
                if not in_class:
                    out.append("-")
                    continue
                if pattern[index : index + 1] != "]":
                    raise ExtractionError(
                        "an escaped hyphen that is not last in its bracket "
                        f"expression would become a range: {pattern!r}"
                    )
                out.append("-")
                rewrites.add("bracket-escaped-hyphen")
                continue
            if escape.isdigit() and escape != "0":
                if in_class:
                    raise ExtractionError(
                        f"backreference inside a bracket expression: {pattern!r}"
                    )
                target = groups.get(int(escape))
                if target is None:
                    raise ExtractionError(
                        f"backreference \\{escape} has no group in {pattern!r}"
                    )
                out.append(_single_literal_of(target))
                rewrites.add("backreference-to-literal")
                continue
            if escape == "/":
                out.append("/")
                continue
            if escape in _ERE_SAFE_ESCAPES:
                if in_class:
                    raise ExtractionError(
                        "POSIX reads a backslash inside a bracket expression as a "
                        f"literal backslash, so \\{escape} would widen: {pattern!r}"
                    )
                out.append("\\" + escape)
                continue
            raise ExtractionError(
                f"no named rewrite claims the escape \\{escape} in {pattern!r}"
            )
        if in_class:
            if char == "]":
                in_class = False
            out.append(char)
            index += 1
            continue
        if char == "[":
            in_class = True
            out.append(char)
            index += 1
            # A `]` or `^]` immediately inside is a literal `]`, not the end.
            if pattern[index : index + 1] == "^":
                out.append("^")
                index += 1
            if pattern[index : index + 1] == "]":
                out.append("]")
                index += 1
            continue
        out.append(char)
        index += 1
    if in_class:
        raise ExtractionError(f"unterminated bracket expression in {pattern!r}")
    return "".join(out)


def compile_pattern(source: str, *, literals: list[str] | None = None) -> dict:
    """Compile one upstream pattern into the record the Nix surface carries."""
    groups = _capture_group_sources(source)
    body, raw_denials, hoisted = _hoist_lookaheads(source)
    rewrites: set[str] = set()
    if hoisted:
        rewrites.add("hoist-negative-lookahead")
    denials = []
    positional = []
    for denial in raw_denials:
        # A `^`-anchored lookahead constrains WHERE the rule may be entered, not
        # what the value may be — see the module docstring. Recorded, not
        # enforced: enforcing it rejects `UID` as a field title, which parses.
        if denial.startswith("^"):
            rewrites.add("line-anchored-lookahead-is-positional")
            positional.append(
                _rewrite_body(denial[1:], _capture_group_sources(denial[1:]), rewrites)
            )
            continue
        denials.append(_rewrite_body(denial, _capture_group_sources(denial), rewrites))
    record: dict[str, Any] = {
        "source": source,
        "ere": _rewrite_body(body, groups, rewrites),
        "deny": denials,
        "denyAtLineStart": positional,
        "rewrites": sorted(rewrites),
    }
    if literals is not None:
        record["literals"] = literals
    return record


def literal_pattern(text: str) -> dict:
    """The pattern record for a production that admits exactly one literal."""
    return {
        "source": text,
        "ere": "".join(("\\" + c) if c in _ERE_SPECIAL else c for c in text),
        "deny": [],
        "denyAtLineStart": [],
        "rewrites": ["literal-to-pattern"],
        "literals": [text],
    }


def literal_set_pattern(texts: list[str]) -> dict:
    """The pattern record for an ``OrderedChoice`` of ``StrMatch`` children.

    This is the first of the two shapes a literal set arrives in. The second —
    an inline regex alternation such as ``/(True|False)/`` — needs no special
    handling here: it is already a pattern. Both end up as a checkable string
    type, and both keep their literal set for the normalizer to enum.
    """
    branches = [
        "".join(("\\" + c) if c in _ERE_SPECIAL else c for c in text) for text in texts
    ]
    return {
        "source": "|".join(texts),
        "ere": "(" + "|".join(branches) + ")",
        "deny": [],
        "denyAtLineStart": [],
        "rewrites": ["ordered-choice-to-alternation"],
        "literals": list(texts),
    }


# ─── naming ──────────────────────────────────────────────────────────────────


def camel(name: str) -> str:
    """``IS_COMPOSITE`` / ``import_from_file`` -> ``isComposite`` / ``importFromFile``."""
    head, *tail = [part for part in name.split("_") if part]
    return head.lower() + "".join(part.capitalize() for part in tail)


# Attribute names the Nix module system reserves at the top level of a module.
# A submodule's CONFIG cannot carry one: `{title = "UID"; options = [...];}` is
# read as an option DECLARATION, and every sibling key then errors out with
# "Module has an unsupported attribute". So an option that would be named one of
# these is renamed, and a collision with no rename is fatal rather than silently
# producing a surface no value can satisfy.
#
# `options` is the only collision the `.sgra` grammar has: the choice vocabulary
# of `SingleChoice(...)` / `MultipleChoice(...)` is textx attribute `options`,
# labelled by a parenthesis rather than a key, so `camel` falls back to it.
# `choices` is the replacement because that is what it is and what the consumer
# DSL calls it.
_RESERVED_MODULE_ATTRS = frozenset(
    {"_file", "_module", "config", "freeformType", "imports", "key", "options"}
)
_OPTION_RENAMES = {"options": "choices"}


def option_name(name: str) -> str:
    """The Nix option name for one grammar key or textx attribute."""
    out = camel(name)
    if out not in _RESERVED_MODULE_ATTRS:
        return out
    renamed = _OPTION_RENAMES.get(out)
    if renamed is None:
        raise ExtractionError(
            f"option name {out!r} is reserved by the Nix module system and has "
            "no entry in _OPTION_RENAMES"
        )
    return renamed


def lower_first(name: str) -> str:
    return name[:1].lower() + name[1:]


def key_of(literal: str | None) -> str | None:
    """The `.sgra` key a production literal labels, if it is one.

    ``'  - TITLE: '`` labels ``TITLE``; ``'('`` labels nothing.
    """
    if literal is None:
        return None
    text = literal.strip()
    if text.startswith("- "):
        text = text[2:]
    text = text.rstrip()
    if text.endswith(":"):
        text = text[:-1]
    if text and all(c.isupper() or c.isdigit() or c == "_" for c in text):
        return text
    return None


def alternative_key(abstract: str, concrete: str) -> str:
    """``GrammarElementField`` + ``GrammarElementFieldSingleChoice`` -> ``singleChoice``."""
    suffix = concrete[len(abstract) :] if concrete.startswith(abstract) else concrete
    return lower_first(suffix) or lower_first(concrete)


# ─── the two access paths ────────────────────────────────────────────────────


def load_metamodel() -> object:
    """Build the textx metamodel of the ``.sgra`` grammar."""
    from textx import metamodel_from_str
    from strictdoc.backend.sdoc.grammar.grammar_builder import SDocGrammarBuilder

    source = SDocGrammarBuilder.create_grammar_grammar()
    metamodel = metamodel_from_str(source)
    metamodel._sgra_source = source  # noqa: SLF001 - carried for provenance
    return metamodel


def _children(node: object) -> list:
    return list(getattr(node, "nodes", None) or [])


def _rule_name(node: object) -> str:
    name = getattr(node, "rule_name", "") or ""
    return name if isinstance(name, str) else ""


def _walk_production(
    node: object, owner: str, known: set[str], *, top: bool = False, depth: int = 0
) -> list[dict]:
    """One rule's own production, as an ordered item tree.

    Stops at any node that is the root of a *different* rule: those become
    ``{kind = "rule";}`` references, which is what keeps a rule's production its
    own rather than the whole grammar inlined.
    """
    if depth > 64:
        raise ExtractionError(f"production of {owner} nests deeper than 64")
    name = _rule_name(node)
    if not top and name in known and name != owner:
        return [{"kind": "rule", "name": name}]
    if name.startswith("__asgn"):
        return [_assignment(node, owner, known, depth)]

    kind = type(node).__name__
    if getattr(node, "suppress", False):
        return []

    def descend(nodes: Sequence[object]) -> list[dict]:
        items: list[dict] = []
        for child in nodes:
            items.extend(_walk_production(child, owner, known, depth=depth + 1))
        return items

    if kind == "StrMatch":
        return [{"kind": "literal", "text": node.to_match}]
    if kind == "RegExMatch":
        return [{"kind": "regex", "pattern": node.to_match}]
    if kind == "Sequence":
        return descend(_children(node))
    if kind == "Optional":
        return [{"kind": "optional", "items": descend(_children(node))}]
    if kind == "OrderedChoice":
        return [
            {
                "kind": "choice",
                "branches": [
                    _walk_production(child, owner, known, depth=depth + 1)
                    for child in _children(node)
                ],
            }
        ]
    if kind in ("ZeroOrMore", "OneOrMore"):
        return [
            {
                "kind": "repeat",
                "min": 0 if kind == "ZeroOrMore" else 1,
                "items": descend(_children(node)),
            }
        ]
    if kind == "Not":
        return [{"kind": "not", "items": descend(_children(node))}]
    if kind == "And":
        return [{"kind": "and", "items": descend(_children(node))}]
    raise ExtractionError(f"{owner}: no handling for arpeggio node {kind}")


def _assignment(node: object, owner: str, known: set[str], depth: int) -> dict:
    name = _rule_name(node)
    multiplicity = _ASSIGNMENT_MULTIPLICITY.get(name)
    if multiplicity is None:
        raise ExtractionError(f"{owner}: unknown assignment rule {name}")
    children = _children(node)
    if len(children) != 1:
        raise ExtractionError(
            f"{owner}: assignment {name} has {len(children)} children, expected 1"
        )
    return {
        "kind": "assign",
        "attr": getattr(node, "_attr_name"),
        "multiplicity": multiplicity,
        "value": _value_of(children[0], owner, known, depth),
    }


def _value_of(node: object, owner: str, known: set[str], depth: int) -> dict:
    """What one assignment assigns: a rule reference, a pattern or a literal."""
    if depth > 64:
        raise ExtractionError(f"{owner}: assignment value nests too deeply")
    name = _rule_name(node)
    if name in known and name != owner:
        return {"kind": "rule", "name": name}
    kind = type(node).__name__
    if kind == "RegExMatch":
        return {"kind": "pattern", "pattern": node.to_match}
    if kind == "StrMatch":
        return {"kind": "literal", "text": node.to_match}
    if kind == "OrderedChoice":
        children = _children(node)
        if children and all(type(c).__name__ == "StrMatch" for c in children):
            return {"kind": "literals", "literals": [c.to_match for c in children]}
        raise ExtractionError(f"{owner}: assignment choice is not a set of literals")
    if kind == "Sequence":
        children = [c for c in _children(node) if not getattr(c, "suppress", False)]
        if len(children) == 1:
            return _value_of(children[0], owner, known, depth + 1)
    raise ExtractionError(f"{owner}: no handling for assignment value node {kind}")


def _references(items: Sequence[dict]) -> list[str]:
    found: list[str] = []
    for item in items:
        kind = item["kind"]
        if kind == "rule":
            found.append(item["name"])
        elif kind == "assign":
            if item["value"]["kind"] == "rule":
                found.append(item["value"]["name"])
        elif kind == "choice":
            for branch in item["branches"]:
                found.extend(_references(branch))
        elif "items" in item:
            found.extend(_references(item["items"]))
    return found


def walk_rules(metamodel: object) -> dict:
    """Walk from ``DocumentGrammarWrapper`` and collect the reachable rules."""
    by_name = {cls.__name__: cls for cls in metamodel}
    known = set(by_name)
    if ROOT_RULE not in known:
        raise ExtractionError(f"{ROOT_RULE} is not a rule of this grammar")

    rules: dict[str, dict] = {}
    pending = [ROOT_RULE]
    while pending:
        name = pending.pop()
        if name in rules:
            continue
        cls = by_name[name]
        production = _walk_production(cls._tx_peg_rule, name, known, top=True)
        alternatives = [alt.__name__ for alt in getattr(cls, "_tx_inh_by", [])]
        rules[name] = {
            "name": name,
            "txType": cls._tx_type,
            "production": production,
            "alternatives": alternatives,
            "attrs": list(getattr(cls, "_tx_attrs", {})),
        }
        pending.extend(_references(production))
        pending.extend(alternatives)
    return rules


# ─── from productions to a typed surface ─────────────────────────────────────


def _collect_assignments(
    items: Sequence[dict], state: dict, optional: bool = False
) -> None:
    """Depth-first over a production, pairing each assignment with its key."""
    for item in items:
        kind = item["kind"]
        if kind == "literal":
            state["last_literal"] = item["text"]
        elif kind == "assign":
            state["found"].append((item, optional, state["last_literal"]))
        elif kind == "optional":
            _collect_assignments(item["items"], state, True)
        elif kind == "repeat":
            _collect_assignments(item["items"], state, optional or item["min"] == 0)
        elif kind == "choice":
            for branch in item["branches"]:
                _collect_assignments(branch, state, optional)
        elif "items" in item:
            _collect_assignments(item["items"], state, optional)


def attributes_of(rule: dict) -> list[dict]:
    """The rule's assignments, merged by name and named from the grammar's keys."""
    state = {"found": [], "last_literal": None}
    _collect_assignments(rule["production"], state)

    merged: dict[str, dict] = {}
    order: list[str] = []
    for item, optional, literal in state["found"]:
        attr = item["attr"]
        is_list = item["multiplicity"] != "one"
        record = merged.get(attr)
        if record is None:
            order.append(attr)
            merged[attr] = {
                "attr": attr,
                "key": key_of(literal),
                "option": None,
                "optional": optional,
                "list": is_list,
                # Non-emptiness is about the repetition, not about the block
                # that wraps it: `RELATIONS` is an optional block holding one or
                # more relations, so the list is nullable AND non-empty.
                "nonEmpty": item["multiplicity"] != "zeroOrMore",
                "value": item["value"],
                "occurrences": 1,
            }
            continue
        # A second assignment to one name is how textx spells "one, then more"
        # — `(options = ChoiceOption) (options *= ChoiceOptionXs)`. The result is
        # a list, non-empty when any contributor was mandatory.
        if record["value"] != item["value"] and not _same_target(
            record["value"], item["value"]
        ):
            raise ExtractionError(
                f"{rule['name']}.{attr} is assigned two different value shapes"
            )
        record["list"] = True
        record["optional"] = record["optional"] and optional
        record["nonEmpty"] = record["nonEmpty"] or (
            item["multiplicity"] != "zeroOrMore"
        )
        record["occurrences"] += 1

    attributes = []
    for attr in order:
        record = merged[attr]
        key = record["key"]
        record["option"] = option_name(key) if key else option_name(attr)
        attributes.append(record)

    names = [record["option"] for record in attributes]
    if len(set(names)) != len(names):
        raise ExtractionError(f"{rule['name']}: two attributes claim one option name")
    return attributes


def _same_target(left: dict, right: dict) -> bool:
    """Whether two assignment values name rules that mean the same thing.

    ``options`` is assigned ``ChoiceOption`` and then ``ChoiceOptionXs``, and the
    second is the first with a suppressed ``", "`` in front of it.
    """
    if left["kind"] != "rule" or right["kind"] != "rule":
        return False
    return right["name"].startswith(left["name"]) or left["name"].startswith(
        right["name"]
    )


def match_pattern_of(rule: dict, rules: dict) -> dict:
    """The pattern record for a textx ``match`` rule, or an alias to another."""
    items = rule["production"]

    # `!ReservedKeyword /…/` — a lookahead over a named literal set.
    if (
        len(items) == 2
        and items[0]["kind"] == "not"
        and items[1]["kind"] == "regex"
        and len(items[0]["items"]) == 1
        and items[0]["items"][0]["kind"] == "rule"
    ):
        denied = rules[items[0]["items"][0]["name"]]
        literals = _literals_of(denied)
        record = compile_pattern(items[1]["pattern"])
        record["deny"] = record["deny"] + [
            "".join(("\\" + c) if c in _ERE_SPECIAL else c for c in text)
            for text in literals
        ]
        record["rewrites"] = sorted(set(record["rewrites"]) | {"negative-lookahead-rule"})
        record["denyRule"] = denied["name"]
        return record

    if len(items) == 1:
        only = items[0]
        if only["kind"] == "regex":
            return compile_pattern(only["pattern"])
        if only["kind"] == "literal":
            return literal_pattern(only["text"])
        if only["kind"] == "rule":
            return {"alias": only["name"]}
        if only["kind"] == "choice":
            return literal_set_pattern(_literals_of(rule))
    raise ExtractionError(
        f"{rule['name']}: no handling for this match-rule production shape"
    )


def _literals_of(rule: dict) -> list[str]:
    items = rule["production"]
    if len(items) == 1 and items[0]["kind"] == "choice":
        literals = []
        for branch in items[0]["branches"]:
            if len(branch) != 1 or branch[0]["kind"] != "literal":
                raise ExtractionError(f"{rule['name']}: branch is not a bare literal")
            literals.append(branch[0]["text"])
        return literals
    raise ExtractionError(f"{rule['name']}: not an ordered choice of literals")


# ─── Nix emission ────────────────────────────────────────────────────────────


def _pattern_type(record: dict) -> Raw:
    return Raw("patternType " + emit_nix.render_attrs(record, 3))


def _value_type(value: dict) -> Raw:
    if value["kind"] == "rule":
        return Raw(value["name"])
    if value["kind"] == "pattern":
        return _pattern_type(compile_pattern(value["pattern"]))
    if value["kind"] == "literal":
        return _pattern_type(literal_pattern(value["text"]))
    if value["kind"] == "literals":
        return _pattern_type(literal_set_pattern(value["literals"]))
    raise ExtractionError(f"no Nix type for assignment value {value['kind']}")


def _attribute_option(rule_name: str, record: dict) -> Raw:
    inner = _value_type(record["value"]).src
    if record["list"]:
        wrapper = "nonEmptyListOf" if record["nonEmpty"] else "listOf"
        inner = f"t.{wrapper} ({inner})"
    if record["optional"]:
        inner = f"t.nullOr ({inner})"

    where = (
        f"`{record['key']}` of `{rule_name}`"
        if record["key"]
        else f"an unlabelled production of `{rule_name}`"
    )
    description = (
        f"{where}. "
        f"{'Optional' if record['optional'] else 'Mandatory'}; "
        f"{'a list' if record['list'] else 'a single value'}. "
        f"Upstream textx attribute `{record['attr']}`."
    )

    default: Any = emit_nix._UNSET  # noqa: SLF001 - the module's own sentinel
    if record["optional"]:
        default = None
    elif record["value"]["kind"] == "literal" and not record["list"]:
        # A production that admits exactly one string is not a choice, so the
        # only possible value is also the only sensible default.
        default = record["value"]["text"]
    return emit_nix.render_option(
        Raw(inner), default=default, description=description, indent=3
    )


def _rule_type(rule: dict, rules: dict) -> Raw:
    name = rule["name"]
    if rule["txType"] == "abstract":
        options = {
            alternative_key(name, alt): emit_nix.render_option(
                Raw(alt),
                description=(
                    f"`{alt}` — one alternative of the `{name}` union. "
                    "attrTag, not a record with optional extras: the module "
                    "system's addCheck predicate never fires inside a submodule, "
                    "so a structural union is the only one with no hole in it."
                ),
                indent=3,
            )
            for alt in rule["alternatives"]
        }
        return Raw("t.attrTag " + emit_nix.render_attrs(options, 2))

    if rule["txType"] == "match":
        record = match_pattern_of(rule, rules)
        if "alias" in record:
            return Raw(record["alias"])
        return _pattern_type(record)

    attributes = attributes_of(rule)
    if not attributes:
        raise ExtractionError(f"{name}: a common rule with no attributes")
    options = {
        record["option"]: _attribute_option(name, record) for record in attributes
    }
    return Raw(
        "t.submodule " + emit_nix.render_attrs({"options": Raw(emit_nix.render_attrs(options, 3))}, 2)
    )


def _production_data(rule: dict, attributes_by_attr: dict) -> Any:
    """The production, as Nix data, so the emitter never hand-types the format."""

    def render(items: Sequence[dict]) -> list:
        out = []
        for item in items:
            entry = {"kind": item["kind"]}
            if item["kind"] == "literal":
                entry["text"] = item["text"]
            elif item["kind"] == "regex":
                entry["pattern"] = item["pattern"]
            elif item["kind"] == "rule":
                entry["name"] = item["name"]
            elif item["kind"] == "assign":
                entry["attr"] = item["attr"]
                entry["multiplicity"] = item["multiplicity"]
                record = attributes_by_attr.get(item["attr"])
                entry["option"] = record["option"] if record else option_name(item["attr"])
                entry["value"] = dict(item["value"])
            elif item["kind"] == "choice":
                entry["branches"] = [render(branch) for branch in item["branches"]]
            elif item["kind"] == "repeat":
                entry["min"] = item["min"]
                entry["items"] = render(item["items"])
            else:
                entry["items"] = render(item["items"])
            out.append(entry)
        return out

    return render(rule["production"])


HEADER_COMMENT = """#
# Written by packages/strictdoc-grammar/extract/extract.py from strictdoc's own
# grammar definition (`SDocGrammarBuilder.create_grammar_grammar()`), reached
# through both the textx metamodel and the arpeggio parser tree. A drift check
# regenerates and diffs, so a stale surface is a red check.
#
# FAITHFUL means: exactly what a `.sgra` file can express, with no opinion of
# ours in it. A value constrained by a regex is a string carrying that regex.
# Opinions belong one layer up, in ./normalized.nix.
#
# Three things to know before reading:
#
# * `types.<Rule>` is one entry per grammar rule reachable from the root rule.
#   Elements, fields and relations are LISTS, never attribute sets: the grammar
#   has all three as ordered lists and enforces the order, while Nix sorts
#   attribute-set keys and would silently reorder the emitted file.
# * A union (field kind, relation type) is `lib.types.attrTag`, not a record
#   with optional extras. It is a genuine discriminated union, and `addCheck`
#   silently never fires inside a submodule, so a post-validation guard would
#   not run.
# * Every pattern carries `source` (upstream's Python regex, verbatim and
#   authoritative) and `ere` (the same constraint in the POSIX dialect
#   `builtins.match` accepts), plus the named `rewrites` that got from one to
#   the other and any `deny` prefixes a lookahead became. The rewrites are
#   exact, never widening.
"""

PATTERN_TYPE_SRC = """p:
    # `p.ere` is p.source in the dialect `builtins.match` speaks; `p.deny`
    # carries the negative lookahead groups that dialect cannot spell, checked
    # as prefix rejections instead. `.*` is deliberate: Nix's `.` matches a
    # newline, so a denied prefix is caught wherever the rest of the string
    # goes.
    if p.deny == []
    then t.strMatching p.ere
    else
      t.addCheck (t.strMatching p.ere)
      (s: !(lib.any (d: builtins.match "(${d}).*" s != null) p.deny))"""


def extract() -> dict:
    """Produce the faithful surface as plain data, ready for ``emit_nix``."""
    metamodel = load_metamodel()
    source = metamodel._sgra_source  # noqa: SLF001
    rules = walk_rules(metamodel)

    clash = sorted(set(rules) & set(PREAMBLE_NAMES))
    if clash:
        raise ExtractionError(f"rule names shadow the generated preamble: {clash}")

    types: dict[str, Any] = {}
    productions: dict[str, Any] = {}
    for name in sorted(rules):
        rule = rules[name]
        types[name] = _rule_type(rule, rules)
        attributes = (
            {record["attr"]: record for record in attributes_of(rule)}
            if rule["txType"] == "common"
            else {}
        )
        productions[name] = {
            "txType": rule["txType"],
            "alternatives": [
                {"key": alternative_key(name, alt), "rule": alt}
                for alt in rule["alternatives"]
            ],
            "items": _production_data(rule, attributes),
        }

    try:
        import strictdoc

        version = getattr(strictdoc, "__version__", None)
    except Exception:  # pragma: no cover - strictdoc is a hard dependency
        version = None

    body = {
        "types": Raw("rec " + emit_nix.render_attrs(types, 1)),
        "productions": productions,
        "meta": {
            "generated": True,
            "strictdocVersion": version,
            "grammarSha256": hashlib.sha256(source.encode("utf-8")).hexdigest(),
            "rootRule": ROOT_RULE,
            "ruleCount": len(rules),
            "metamodelRuleCount": len({cls.__name__ for cls in metamodel}),
        },
    }
    return {"body": body, "ruleCount": len(rules), "rules": sorted(rules)}


def render(surface: dict) -> str:
    text = emit_nix.render_file(
        surface["body"],
        "{lib}",
        preamble=[
            ("t", Raw("lib.types")),
            # `inherit`, not `mkOption = lib.mkOption`, which statix rejects as
            # [04] "assignment instead of inherit from" — a warning, but the
            # repository's pre-commit statix hook exits non-zero on one and a
            # generated file that cannot be committed is not generated.
            (None, Raw("inherit (lib) mkOption;")),
            ("patternType", Raw(PATTERN_TYPE_SRC)),
        ],
        header_comment=HEADER_COMMENT,
    )
    return emit_nix.format_nix(text)


def build_parser() -> argparse.ArgumentParser:
    """Command line: where to write, and whether to diff instead of write."""
    parser = argparse.ArgumentParser(
        prog="strictdoc-grammar-extract",
        description="Extract StrictDoc's .sgra grammar into a faithful Nix surface.",
    )
    parser.add_argument(
        "--output",
        default=DEFAULT_OUTPUT,
        help="path of the faithful surface to write (default: %(default)s)",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="regenerate and diff instead of writing; non-zero exit on drift",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    surface = extract()
    status = emit_nix.write_or_check(args.output, render(surface), args.check)
    print(
        f"{surface['ruleCount']} rules reachable from {ROOT_RULE}: "
        + ", ".join(surface["rules"]),
        file=sys.stderr,
    )
    return status


if __name__ == "__main__":
    sys.exit(main())
