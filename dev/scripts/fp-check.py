#!/usr/bin/env python3
# cspell:ignore uids
"""fp-check -- SLICE-FP-DETECTOR. Suspect-link detection over the JSON export.

Usage: fp-check.py <export.json>

Hashes every node's contract-bearing fields (see sdoc_fp.contract_fields)
and compares each PARENT_FP entry against the current hash of the parent it
names. Reports four cases distinctly:

  never-signed  the recorded hash is the placeholder (0000000) -- the
                normal state of an edge nobody has accepted yet
  drifted       a real recorded hash no longer matches the parent's current
                hash
  unbacked      the entry names a parent this node has no relation to
                (MECH-FP-RELATION-LINT)
  deleted       the entry names a UID that no longer exists in the graph

Exit status is non-zero when any drifted, unbacked, or deleted entry is
found. never-signed does not fail the check.

Generate the export first with a CLEAN output directory -- incremental
export produces false greens (see the sdoc skill's gotcha list):

    rm -rf output && strictdoc export . --formats=json --output-dir output
    dev/scripts/fp-check.py output/json/index.json
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sdoc_fp import PLACEHOLDER, build_uid_index, contract_hash, iter_nodes, load_index, parse_parent_fp, relation_parent_uids

FAILING_CASES = {"drifted", "unbacked", "deleted"}
REPORT_ORDER = ("deleted", "unbacked", "drifted", "never-signed")


def check(index: dict):
    """Returns (findings, total_entries) -- total_entries counts every
    PARENT_FP entry examined, including ones that matched cleanly and so
    produced no finding."""
    by_uid = build_uid_index(index)
    findings = []
    total_entries = 0
    for _doc_title, node in iter_nodes(index):
        uid = node.get("UID")
        raw = node.get("PARENT_FP")
        if not raw:
            continue
        related = relation_parent_uids(node)
        for parent_uid, recorded in parse_parent_fp(raw):
            total_entries += 1
            parent = by_uid.get(parent_uid)
            if parent is None:
                findings.append({"node": uid, "parent": parent_uid, "case": "deleted"})
                continue
            if parent_uid not in related:
                findings.append({"node": uid, "parent": parent_uid, "case": "unbacked"})
                continue
            if recorded == PLACEHOLDER:
                findings.append({"node": uid, "parent": parent_uid, "case": "never-signed"})
                continue
            current = contract_hash(parent)
            if recorded != current:
                findings.append(
                    {
                        "node": uid,
                        "parent": parent_uid,
                        "case": "drifted",
                        "recorded": recorded,
                        "current": current,
                    }
                )
    return findings, total_entries


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("export_json", type=Path)
    args = parser.parse_args()

    index = load_index(args.export_json)
    findings, total_entries = check(index)

    by_case: dict = {}
    for f in findings:
        by_case.setdefault(f["case"], []).append(f)

    for case in REPORT_ORDER:
        entries = by_case.get(case, [])
        if not entries:
            continue
        print(f"\n== {case} ({len(entries)}) ==")
        for e in entries:
            if case == "drifted":
                print(f"  {e['node']} -> {e['parent']}: recorded {e['recorded']}, current {e['current']}")
            else:
                print(f"  {e['node']} -> {e['parent']}")

    failing = sum(len(by_case.get(c, [])) for c in FAILING_CASES)
    never_signed = len(by_case.get("never-signed", []))
    signed_ok = total_entries - len(findings)
    noun = "entry" if total_entries == 1 else "entries"
    print(
        f"\n{total_entries} fingerprint {noun} checked: "
        f"{signed_ok} signed and current, {never_signed} never signed, {failing} suspect"
    )

    return 1 if failing else 0


if __name__ == "__main__":
    sys.exit(main())
