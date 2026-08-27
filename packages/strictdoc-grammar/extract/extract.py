# cspell:ignore asgn lookaheads oneormore zeroormore sgra textx
"""Faithful extraction of StrictDoc's ``.sgra`` grammar into raw Nix records.

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

FAITHFUL MEANS FAITHFUL, AND THAT IS A CONSTRAINT ON THIS FILE. What it writes
is the grammar's own production tree, rule by rule, with every pattern exactly
as upstream spells it. It classifies nothing, rewrites nothing, and emits no
types: a layer whose whole promise is that nothing was transformed cannot also
carry a record of transformations. Turning a pattern into a checkable Nix type
— the POSIX dialect rewrite, the lookaheads lifted out of it, a literal
alternation read as a vocabulary — is ``normalize.py``'s job, and the code for
it lives in ``decompose.py``, which this module must never import.

── One thing that is NOT re-derivation and had to be decided here ────────────

**Attribute names come from the grammar's own literal keys.** ``'    ROLE: '``
is in the production immediately before the assignment it labels, so ``role``
is extracted, not typed by a person — and it is the name a ``.sgra`` file
actually carries, which the textx attribute name (``relation_role``) is not.
Where a production has no key (``SingleChoice(a, b)`` labels its options with a
parenthesis), the textx attribute name is the fallback. Both spellings are kept
so nothing is lost. The naming rules themselves live in ``shape.py``, shared
with the decomposition so the two cannot drift.
"""

from __future__ import annotations

import argparse
import hashlib
import sys
from typing import Any, Sequence

import emit_nix
from shape import ExtractionError, alternative_key, attributes_of, option_name

DEFAULT_OUTPUT = "packages/strictdoc-grammar/lib/faithful.nix"

# Where the walk starts. Everything the `.sgra` grammar can express is reachable
# from here; what is not reachable is document-side and belongs to `.sdoc`.
ROOT_RULE = "DocumentGrammarWrapper"

# textx spells a multiplicity by naming the synthetic assignment rule.
_ASSIGNMENT_MULTIPLICITY = {
    "__asgn_plain": "one",
    "__asgn_bool": "one",
    "__asgn_oneormore": "oneOrMore",
    "__asgn_zeroormore": "zeroOrMore",
    "__asgn_list": "zeroOrMore",
}


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
# FAITHFUL means: the grammar's own production tree, rule by rule, with no
# opinion of ours in it. There are no types here and no `lib` to build them
# with — a value constrained by a regex is that regex, spelled the way upstream
# spells it, lookahead groups and Python-only escapes and all.
#
# THE ABSENCE OF A `types` BLOCK IS THE POINT. Deciding what a pattern MEANS —
# rewriting it into the POSIX dialect `builtins.match` speaks, lifting a
# lookahead out of it, reading an alternation as a vocabulary — is a
# transformation, and a layer that promises nothing was transformed cannot
# carry a record of transformations. ./normalized.nix computes the types from
# the records below, and names every rewrite it performs.
#
# Two things to know before reading:
#
# * `productions.<Rule>` is one entry per grammar rule reachable from the root
#   rule, as an ordered item tree: literals, patterns, references to other
#   rules, and the assignments that name a rule's attributes. Order is the
#   grammar's and is enforced by it.
# * An assignment carries BOTH spellings of its name — `attr` is upstream's
#   textx attribute, `option` is the key a `.sgra` file actually writes, read
#   off the literal immediately in front of it.
"""


def extract() -> dict:
    """Produce the faithful surface as plain data, ready for ``emit_nix``."""
    metamodel = load_metamodel()
    source = metamodel._sgra_source  # noqa: SLF001
    rules = walk_rules(metamodel)

    productions: dict[str, Any] = {}
    for name in sorted(rules):
        rule = rules[name]
        attributes = (
            {
                record["attr"]: record
                for record in attributes_of(name, rule["production"])
            }
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
    # No argument pattern and no `let`: the body is data all the way down, so
    # there is nothing for `lib` to do here. `import ./faithful.nix` takes it
    # as it is.
    text = emit_nix.render_file(
        surface["body"],
        None,
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
