#!/usr/bin/env python3
# cspell:ignore uids
"""fp-accept -- SLICE-FP-DETECTOR. Sign PARENT_FP entries to current hashes.

Usage: fp-accept.py <export.json> --repo-root PATH UID [UID ...]

For each named node, recomputes the hash of every parent it has a `Parent`
relation to (any role) and writes a PARENT_FP entry for it -- unless
MECH-FP-ACCEPT-READINESS refuses: a MECHANISM/SLICE/INVARIANT/SPIKE parent
below interface-settled, or a DECISION parent whose STATUS is open.

This is the ONLY thing that writes PARENT_FP (DEC-FINGERPRINT-IN-NODE), and
it writes through sdoc_model (MECH-SDOC-EDIT-VIA-MODEL) like every other
writer. Two consequences of that, both of which used to be this script's
problem:

* The glob-and-grep scan for a `UID: <uid>` line is gone. The model gives
  each node its own source file, which the JSON export does not carry.
* `strictdoc format .` afterwards is gone. SDWriter emits the canonical form,
  so the file this writes is already formatted.

Re-export with a CLEAN output directory before the next fp-check -- a stale
export is the false-green gotcha the sdoc skill warns about, and that part is
still the caller's.

Hashes still come from the JSON export: this changes the write path only.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sdoc_fp import build_uid_index, contract_hash, format_parent_fp, is_ready, load_index, parse_parent_fp, relation_parent_uids
from sdoc_model import SdocError, open_graph


def accept(index: dict, repo_root: Path, uids: list) -> int:
    by_uid = build_uid_index(index)
    # One load for every UID on the command line: the graph load is the
    # expensive step and this script routinely signs several at once.
    graph = open_graph(repo_root)
    exit_code = 0

    for uid in uids:
        node = by_uid.get(uid)
        if node is None:
            print(f"error: {uid} not found in export", file=sys.stderr)
            exit_code = 1
            continue

        node_type = node["_NODE_TYPE"]
        if node_type == "DECISION":
            print(f"error: {uid} is a DECISION -- decisions carry no PARENT_FP", file=sys.stderr)
            exit_code = 1
            continue

        parents = sorted(relation_parent_uids(node))
        if not parents:
            print(f"{uid}: no Parent relations, nothing to sign")
            continue

        existing = dict(parse_parent_fp(node.get("PARENT_FP")))
        signed, skipped = [], []
        for parent_uid in parents:
            parent = by_uid.get(parent_uid)
            if parent is None:
                skipped.append((parent_uid, "parent not found in export"))
                continue
            ready, reason = is_ready(parent)
            if not ready:
                skipped.append((parent_uid, reason))
                continue
            existing[parent_uid] = contract_hash(parent)
            signed.append(parent_uid)

        if not signed:
            print(f"{uid}: nothing ready to sign ({len(skipped)} parent(s) still moving)")
            for parent_uid, reason in skipped:
                print(f"  skipped {parent_uid}: {reason}")
            continue

        try:
            graph.set_field(uid, "PARENT_FP", format_parent_fp(list(existing.items())))
            source = graph.path_of(graph.node(uid))
        except SdocError as exc:
            print(f"error: {uid}: {exc}", file=sys.stderr)
            exit_code = 1
            continue

        print(f"{uid}: signed {len(signed)} parent(s) in {source.relative_to(repo_root)}")
        for parent_uid in signed:
            print(f"  {parent_uid}: {existing[parent_uid]}")
        for parent_uid, reason in skipped:
            print(f"  skipped {parent_uid}: {reason}")

    for path in graph.save():
        print(f"wrote {path.relative_to(repo_root)}")
    return exit_code


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("export_json", type=Path)
    parser.add_argument("--repo-root", type=Path, default=Path("."))
    parser.add_argument("uids", nargs="+")
    args = parser.parse_args()

    index = load_index(args.export_json)
    code = accept(index, args.repo_root.resolve(), args.uids)
    if code == 0:
        print("\nRe-export with a clean output directory before the next fp-check.")
    return code


if __name__ == "__main__":
    sys.exit(main())
