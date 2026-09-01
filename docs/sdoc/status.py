#!/usr/bin/env python3
"""Summarize the design graph from a StrictDoc JSON export.

    strictdoc export . --formats=json --output-dir /tmp/sdoc-out
    python3 docs/sdoc/status.py /tmp/sdoc-out/json/index.json

Filtering happens here rather than on the strictdoc command line because
--filter-nodes is silently ignored by the JSON exporter.
"""

from __future__ import annotations

import json
import sys
from collections import Counter

# A design node is anything the export types with an element tag of its own;
# DEC-UID-OUTLIVES-TYPE retired prefix-keyed discovery on 2026-08-30.
NOT_NODES = {"DOCUMENT", "SECTION", "TEXT"}


def nodes(obj):
    """Yield every design node in the export, at any nesting depth."""
    if isinstance(obj, dict):
        node_type = obj.get("_NODE_TYPE")
        if isinstance(node_type, str) and node_type not in NOT_NODES and isinstance(obj.get("UID"), str):
            yield obj
        for value in obj.values():
            yield from nodes(value)
    elif isinstance(obj, list):
        for value in obj:
            yield from nodes(value)


SETTLED = {"interface-settled", "implemented", "verified"}


def dependencies(node):
    """Every node this one depends on: Parent relation targets AND fingerprint
    parents.

    File relations are skipped: their VALUE is a repository path, not a UID.
    Child relations are skipped too: Contains and Produces point DOWN at
    something the node owns, which is not a dependency.

    PARENT_FP entries DO count. A node can record a fingerprint for a parent
    without carrying an edge to it -- nothing enforces the pair yet (see
    MECH-FP-RELATION-LINT) -- and ignoring the fingerprint half is exactly how
    an earlier version of this script reported a blocked slice as ready.
    """
    out = {
        r.get("VALUE")
        for r in (node.get("RELATIONS") or [])
        if r.get("VALUE") and r.get("TYPE") not in ("File", "Child")
    }
    for entry in str(node.get("PARENT_FP") or "").split():
        if ":" in entry:
            out.add(entry.rsplit(":", 1)[0])
    return {uid for uid in out if uid}


def closure_verdict(root, by_uid):
    """Walk the contract closure and apply DEC-LOCAL-IMPLEMENTABILITY."""
    seen, stack, blockers, freedoms = set(), [root["UID"]], [], 0
    while stack:
        uid = stack.pop()
        if uid in seen:
            continue
        seen.add(uid)
        node = by_uid.get(uid)
        if node is None:
            blockers.append(f"{uid} (no such node)")
            continue
        if node.get("_NODE_TYPE") == "DECISION":
            status = node.get("STATUS")
            if status == "open":
                freedoms += 1
                blockers.append(f"{uid} (decision still open)")
            elif status == "superseded":
                blockers.append(f"{uid} (depends on a SUPERSEDED decision)")
        elif node.get("DEPTH") not in SETTLED:
            blockers.append(f"{uid} (DEPTH: {node.get('DEPTH')})")
        stack.extend(dependencies(node))
    return not blockers, blockers, freedoms

def show(label, rows):
    print(f"\n{label} ({len(rows)})")
    for node in rows:
        print(f"  {node['UID']:34} {node.get('TITLE', '')}")


def main(path: str) -> int:
    found = list(nodes(json.load(open(path))))
    print(f"nodes: {len(found)}")
    print(f"  type:     {dict(Counter(n['_NODE_TYPE'] for n in found))}")
    print(f"  depth:    {dict(Counter(str(n.get('DEPTH') or '-') for n in found))}")
    print(f"  authored: {dict(Counter(n.get('AUTHORED_BY') for n in found))}")

    show("OPEN decisions - the live degrees of freedom",
         [n for n in found if n.get("STATUS") == "open"])
    show("Needs design or a spike",
         [n for n in found if str(n.get("DEPTH", "")).startswith("needs")])
    show("Backlog - ungroomed",
         [n for n in found if n.get("DEPTH") == "sketch" and n["_NODE_TYPE"] != "NARRATIVE"])
    by_uid = {n["UID"]: n for n in found}
    for slice_node in (n for n in found if n["_NODE_TYPE"] == "WORK"):
        ready, blockers, freedoms = closure_verdict(slice_node, by_uid)
        state = "READY" if ready else "BLOCKED"
        print(f"\n{state}  {slice_node['UID']}  (degrees of freedom: {freedoms})")
        for blocker in blockers:
            print(f"    blocked by  {blocker}")

    stale = [n for n in found
             if n.get("PARENT_FP") and ":0000000" in str(n.get("PARENT_FP"))]
    if stale:
        print(f"\nplaceholder fingerprints, never computed ({len(stale)})")
        print("  no contract has actually been signed off yet")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "build/json/index.json"))
