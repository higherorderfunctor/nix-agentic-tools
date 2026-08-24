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

NODE_PREFIXES = ("DEC", "MECH", "SLICE", "SPIKE", "INV")


def nodes(obj):
    """Yield every design node in the export, at any nesting depth."""
    if isinstance(obj, dict):
        uid = obj.get("UID")
        if isinstance(uid, str) and uid.split("-")[0] in NODE_PREFIXES:
            yield obj
        for value in obj.values():
            yield from nodes(value)
    elif isinstance(obj, list):
        for value in obj:
            yield from nodes(value)


def show(label, rows):
    print(f"\n{label} ({len(rows)})")
    for node in rows:
        print(f"  {node['UID']:34} {node.get('TITLE', '')}")


def main(path: str) -> int:
    found = list(nodes(json.load(open(path))))
    print(f"nodes: {len(found)}")
    print(f"  type:     {dict(Counter(n['UID'].split('-')[0] for n in found))}")
    print(f"  depth:    {dict(Counter(str(n.get('DEPTH') or '-') for n in found))}")
    print(f"  authored: {dict(Counter(n.get('AUTHORED_BY') for n in found))}")

    show("OPEN decisions - the live degrees of freedom",
         [n for n in found if n.get("STATUS") == "open"])
    show("Needs design or a spike",
         [n for n in found if str(n.get("DEPTH", "")).startswith("needs")])
    show("Backlog - ungroomed",
         [n for n in found if n.get("DEPTH") == "sketch"])
    show("Ready to implement - settled, nothing open of its own",
         [n for n in found
          if n["UID"].startswith("SLICE") and n.get("DEPTH") == "interface-settled"])

    stale = [n for n in found
             if n.get("PARENT_FP") and ":0000000" in str(n.get("PARENT_FP"))]
    if stale:
        print(f"\nplaceholder fingerprints, never computed ({len(stale)})")
        print("  no contract has actually been signed off yet")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "build/json/index.json"))
