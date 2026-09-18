#!/usr/bin/env python3
"""commentary-check -- the executing guard for the COMMENTARY element.

Usage: commentary-check.py <export.json>

A COMMENTARY is a remark ABOUT the canon: a gap, an architecture note, a
verdict on a node, a note on one edge. The whole reason it is an element
rather than a narrative row carrying a bracketed word is that a validator can
be run against it. This is that validator, and it ships in the same commit as
the element because INV-GUARDS-MUST-EXECUTE forbids the other order.

Four rules, each covering something the PARSER cannot:

* A remark must remark on something. The grammar cannot require a relation,
  only a field, so a COMMENTARY with no Remarks_On parses clean and says
  nothing about anything.

* EDGE, when present, names one relation structurally as "<FROM> <ROLE> <TO>",
  because a strictdoc relation is a TYPE/VALUE/ROLE triple with no identity of
  its own -- there is nothing to point a UID at. Three whitespace-separated
  tokens, which is unambiguous only because every role in this grammar is
  Snake_Case and contains no space.

* That relation must EXIST. This is the rule with teeth: an EDGE naming a
  relation nobody wrote is a remark about nothing, and it exports clean,
  because the string is just a string to the parser.

* Both endpoints of an EDGE must also be Remarks_On targets. That redundancy
  is deliberate and is what makes the PARSER refuse a dangling end -- a
  Remarks_On to a UID that does not exist fails the export, so writing the
  endpoints twice buys parser-enforced existence for a field the parser cannot
  read. It is the same bargain PARENT_FP already makes.

The corpus carries zero COMMENTARY nodes today. A checker that reports
"0 checked: 0 findings" must still be able to FAIL, which is why the
Nix wrapper runs a fixture through it rather than trusting a green over an
empty set.

Generate the export with a CLEAN output directory -- incremental export
produces false greens:

    rm -rf output && strictdoc export . --formats=json --output-dir output
    dev/scripts/commentary-check.py output/json/index.json
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sdoc_fp import iter_nodes, load_index

TAG = "COMMENTARY"
ROLE = "Remarks_On"


def relations_of(node: dict) -> list:
    return node.get("RELATIONS", []) or []


def remarks_targets(node: dict) -> set:
    return {r.get("VALUE") for r in relations_of(node) if r.get("ROLE") == ROLE}


def edge_exists(index_by_uid: dict, source: str, role: str, target: str) -> bool:
    node = index_by_uid.get(source)
    if node is None:
        return False
    return any(
        r.get("ROLE") == role and r.get("VALUE") == target for r in relations_of(node)
    )


def check(index: dict) -> tuple:
    by_uid = {n["UID"]: n for _, n in iter_nodes(index) if "UID" in n}
    findings = []
    checked = 0
    for document_title, node in iter_nodes(index):
        if node.get("_NODE_TYPE") != TAG:
            continue
        checked += 1
        uid = node.get("UID", "(no UID)")

        def find(msg: str) -> None:
            findings.append((document_title, uid, msg))

        targets = remarks_targets(node)
        if not targets:
            find(f"carries no {ROLE} relation; a remark must remark on something")

        edge = (node.get("EDGE") or "").strip()
        if not edge:
            continue
        parts = edge.split()
        if len(parts) != 3:
            find(
                f"EDGE {edge!r} is not three whitespace-separated tokens "
                f"'<FROM> <ROLE> <TO>'"
            )
            continue
        source, role, target = parts
        if not edge_exists(by_uid, source, role, target):
            find(
                f"EDGE {edge!r} names a relation that does not exist: "
                f"{source} carries no {role} to {target}"
            )
        for end in (source, target):
            if end not in targets:
                find(
                    f"EDGE names {end}, which is not also a {ROLE} target; both "
                    f"ends are written twice so the parser can refuse a dangling one"
                )
    return checked, findings


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("export_json", type=Path)
    args = parser.parse_args()

    checked, findings = check(load_index(args.export_json))
    for document_title, uid, msg in findings:
        print(f"{uid} ({document_title}): {msg}", file=sys.stderr)
    print(f"{checked} commentary node(s) checked: {len(findings)} finding(s)")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
