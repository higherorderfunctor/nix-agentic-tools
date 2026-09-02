#!/usr/bin/env python3
# cspell:ignore sgra sdoc
"""grammar-groups-check -- the static coverage guard for the Grammars tab.

Usage: grammar-groups-check.py <grammar.sgra> <grammar-groups.json>

Everything else on the board is derived from the grammar. The layout in
docs/sdoc/board/grammar-groups.json is the one deliberate exception: the
operator groups the grammar's node types BY HAND (2026-09-02) so the Grammars
tab reads as a reasoned map rather than a sorted list, and the justification
for hand-authoring it at all was "I want a check to guard". This is that
check. It runs in `nix flake check`; the page runs the same rules at load
time and shows a banner, but a banner is only seen by whoever opens the tab.

The type universe is the grammar's element names -- `set(parse_sgra(...))`,
the SAME function over the SAME file the daemon feeds the page, so the check
and the tab agree byte-for-byte. StrictDoc's built-in TEXT element is not
declared in the .sgra and is not rendered by the tab, so nothing here
subtracts it; do not add a subtraction.

Rules, one finding each, on stderr:

* Every grammar type is placed exactly once. A type placed nowhere is a
  finding unless one group takes the "rest"; a type placed twice is a
  finding regardless.
* Every placed name is a grammar type. A stale name (a type that was renamed
  or removed) is a finding, and a UID prefix (REQ-) written where the element
  name (REQUIREMENT) belongs is called out as such rather than as merely
  stale.
* "rest" appears at most once and means every type not placed elsewhere. The
  types it absorbs are listed on stdout so the operator sees what is still
  unsorted.
* A "grid" group has two axes of GRID_SIZE distinct words each and exactly one
  type per (row, column) pair; a cell naming a word outside its axis, an
  empty cell, or a doubly-filled cell is a finding.
* A "cards" group lists type names, or is the "rest".
* Any other widget is a finding.
* An empty type universe is a hard failure: a blind check must not pass.

The layout shape this enforces is the shape the page assumes; change both
together.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from scribe_grammar import parse_sgra

AXES = ("rows", "columns")
GRID_SIZE = 2
REST = "rest"
WIDGETS = ("cards", "grid")


def label(entry: object, kind: str, index: int) -> str:
    title = entry.get("title") if isinstance(entry, dict) else None
    return title if isinstance(title, str) and title else f"{kind} #{index + 1}"


def check(grammar: dict, layout: object) -> tuple:
    """Return (checked, findings, rest) where rest is (where, [types]) or None."""
    universe = set(grammar)
    findings: list = []
    find = findings.append
    if not universe:
        find("the grammar declares no element types; a blind check must not pass")
        return 0, findings, None

    # "REQ-" -> "REQUIREMENT", keyed without the dash so "REQ" is caught too
    by_prefix = {el["prefix"].rstrip("-"): tag for tag, el in grammar.items() if el["prefix"]}
    placed: dict = {}
    rest_at: list = []

    def place(name: object, where: str) -> None:
        if not isinstance(name, str):
            find(f"{where}: type names must be strings, got {name!r}")
            return
        if name.rstrip("-") in by_prefix:
            tag = by_prefix[name.rstrip("-")]
            find(f"{where}: {name!r} is the UID prefix of {tag}, not a type name; write {tag}")
        elif name.endswith("-"):
            find(f"{where}: {name!r} looks like a UID prefix, not a type name")
        elif name not in universe:
            find(f"{where}: {name} is not a type the grammar declares (stale?)")
        if name in placed:
            find(f"{where}: {name} is already placed at {placed[name]}; a type is placed exactly once")
        else:
            placed[name] = where

    def check_cards(group: dict, where: str) -> None:
        types = group.get("types")
        if types == REST:
            rest_at.append(where)
            if len(rest_at) > 1:
                find(f"{where}: {REST!r} already appears at {rest_at[0]}; at most one group takes the rest")
        elif isinstance(types, list):
            for name in types:
                place(name, where)
        else:
            find(f"{where}: 'types' must be a list of type names or the string {REST!r}")

    def check_grid(group: dict, where: str) -> None:
        axes = group.get("axes")
        axes_ok = (
            isinstance(axes, dict)
            and set(axes) == set(AXES)
            and all(
                isinstance(axes[axis], list)
                and len(axes[axis]) == GRID_SIZE
                and all(isinstance(word, str) for word in axes[axis])
                and len(set(axes[axis])) == GRID_SIZE
                for axis in AXES
            )
        )
        if not axes_ok:
            find(f"{where}: a grid needs 'axes' with 'rows' and 'columns' of {GRID_SIZE} distinct words each")
        cells = group.get("cells")
        if not isinstance(cells, dict):
            find(f"{where}: a grid needs 'cells' mapping each type to [row, column]")
            return
        filled: dict = {}
        for name, coords in cells.items():
            place(name, where)
            if not (isinstance(coords, list) and len(coords) == 2 and all(isinstance(c, str) for c in coords)):
                find(f"{where}: cell {name} must be [row, column], got {coords!r}")
                continue
            if not axes_ok:
                continue
            row, column = coords
            known = True
            if row not in axes["rows"]:
                find(f"{where}: {name} names row {row!r}, not one of {axes['rows']}")
                known = False
            if column not in axes["columns"]:
                find(f"{where}: {name} names column {column!r}, not one of {axes['columns']}")
                known = False
            if not known:
                continue
            if (row, column) in filled:
                find(f"{where}: cell ({row}, {column}) holds both {filled[(row, column)]} and {name}; one type per cell")
            else:
                filled[(row, column)] = name
        if axes_ok:
            for row in axes["rows"]:
                for column in axes["columns"]:
                    if (row, column) not in filled:
                        find(f"{where}: cell ({row}, {column}) is empty; every axis pair must be filled")

    sections = layout.get("sections") if isinstance(layout, dict) else None
    if not isinstance(sections, list) or not sections:
        find("the layout must be an object with a non-empty 'sections' list")
        return len(universe), findings, None
    for s_index, section in enumerate(sections):
        s_where = label(section, "section", s_index)
        groups = section.get("groups") if isinstance(section, dict) else None
        if not isinstance(groups, list) or not groups:
            find(f"{s_where}: a section is an object with a non-empty 'groups' list")
            continue
        for g_index, group in enumerate(groups):
            where = f"{s_where}/{label(group, 'group', g_index)}"
            if not isinstance(group, dict):
                find(f"{where}: a group is an object")
                continue
            widget = group.get("widget")
            if widget == "cards":
                check_cards(group, where)
            elif widget == "grid":
                check_grid(group, where)
            else:
                find(f"{where}: widget {widget!r} is not one of {WIDGETS}")

    unplaced = sorted(universe - set(placed))
    if rest_at:
        return len(universe), findings, (rest_at[0], unplaced)
    for name in unplaced:
        find(f"{name} is declared in the grammar but placed nowhere, and no group takes the {REST!r}")
    return len(universe), findings, None


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("grammar_sgra", type=Path)
    parser.add_argument("groups_json", type=Path)
    args = parser.parse_args()

    try:
        grammar = parse_sgra(args.grammar_sgra)
        layout = json.loads(args.groups_json.read_text())
    except (OSError, ValueError) as error:
        print(f"cannot read the inputs: {error}", file=sys.stderr)
        print("0 grammar type(s) checked: 1 finding(s)")
        return 1

    checked, findings, rest = check(grammar, layout)
    for msg in findings:
        print(msg, file=sys.stderr)
    if rest is not None:
        where, types = rest
        print(f"{where} takes the rest: {', '.join(types) if types else '(nothing left)'}")
    print(f"{checked} grammar type(s) checked: {len(findings)} finding(s)")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
