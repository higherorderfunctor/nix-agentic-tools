# cspell:ignore asgn oneormore zeroormore sgra textx
"""The shape a `.sgra` production tree has: names, and merged attributes.

Shared by ``extract.py``, which reads productions off StrictDoc's own grammar
and writes them to ``lib/faithful.nix``, and by ``decompose.py``, which reads
those same records back out of that file and builds Nix types from them. It is
the one thing both halves need and neither owns.

Nothing here transforms a value. Naming a grammar key ``TITLE`` as the option
``title``, and merging two assignments to one attribute into one record, are
both readings of the production — they lose nothing and invent nothing. The
transformations live in ``decompose.py``, one layer up.
"""

from __future__ import annotations

from typing import Sequence


class ExtractionError(Exception):
    """Raised when the grammar has a shape this extractor does not recognize.

    Deliberately fatal. An unrecognized shape must redden a regeneration rather
    than quietly produce a surface that is missing part of the grammar.
    """


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


def camel(name: str) -> str:
    """``IS_COMPOSITE`` / ``import_from_file`` -> ``isComposite`` / ``importFromFile``."""
    head, *tail = [part for part in name.split("_") if part]
    return head.lower() + "".join(part.capitalize() for part in tail)


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


def attributes_of(name: str, items: Sequence[dict]) -> list[dict]:
    """The rule's assignments, merged by name and named from the grammar's keys."""
    state: dict = {"found": [], "last_literal": None}
    _collect_assignments(items, state)

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
                "multiplicities": [item["multiplicity"]],
            }
            continue
        # A second assignment to one name is how textx spells "one, then more"
        # — `(options = ChoiceOption) (options *= ChoiceOptionXs)`. The result is
        # a list, non-empty when any contributor was mandatory.
        if record["value"] != item["value"] and not _same_target(
            record["value"], item["value"]
        ):
            raise ExtractionError(f"{name}.{attr} is assigned two different value shapes")
        record["list"] = True
        record["optional"] = record["optional"] and optional
        record["nonEmpty"] = record["nonEmpty"] or (item["multiplicity"] != "zeroOrMore")
        record["occurrences"] += 1
        record["multiplicities"].append(item["multiplicity"])

    attributes = []
    for attr in order:
        record = merged[attr]
        key = record["key"]
        record["option"] = option_name(key) if key else option_name(attr)
        attributes.append(record)

    names = [record["option"] for record in attributes]
    if len(set(names)) != len(names):
        raise ExtractionError(f"{name}: two attributes claim one option name")
    return attributes
