#!/usr/bin/env python3
"""Report the queue, write the ``drained`` flag, and render the lineage forest.

Two behaviors the drain depends on:

1. **The status file exists with ``{"drained": false}`` from the start.**
   ``queue_init.py`` writes it while seeding. A MISSING file evaluates to false
   with only a debug-level log, and so does malformed JSON -- so absent is not
   an error, it is an invisible hang.
2. **``drained: true`` is written in the same operation that observes the queue
   empty**, because the consumer checks the flag AFTER each iteration body.
   Computing a status and writing it later could publish a queue state that has
   already moved.

``drained`` requires ``ready``, ``proposed``, ``claimed`` and ``orphaned`` all
at zero -- not merely "no ready items". Those four are exactly the states from
which new work can still appear, and a late-proposer mints its child WHILE it is
being worked. A flag that ignored ``claimed`` would go true one moment before
the child existed, and the consumer would stop and drop it.

A zero denominator is not drained: an empty or missing ``items/`` reports a
refusal and leaves the flag false, because "everything is finished" and "the
enumeration found nothing" are otherwise indistinguishable.

Exit codes: 0 always (a report is not a verdict), 1 error.
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import queuelib as q  # noqa: E402

GLYPH_LAST = "`-- "
GLYPH_MID = "|-- "
GLYPH_PIPE = "|   "
GLYPH_GAP = "    "


def render_tree(root, status):
    items, children, roots = q.lineage_forest(root)
    now = q.now_epoch()
    lines = [
        f"profile={status['profile']} root={root}",
        f"max_lineage_depth={status['max_lineage_depth']} "
        f"total={status['total']} drained={json.dumps(status['drained'])}",
        "",
    ]

    def label(item_id):
        item = items[item_id]
        state = q.view_state(root, item, now)
        bits = [
            item_id,
            f"d{item.get('lineage_depth', 0)}",
            state,
            f"{item['duration_units']}u",
        ]
        if item.get("answer") is not None:
            ok = "ok" if item["answer"] == item["expected"] else "WRONG-ANSWER"
            bits.append(f"answer={item['answer']} {ok}")
        if item.get("dead_letter_reason"):
            bits.append(f"DEAD: {item['dead_letter_reason']}")
        if item.get("attempts", 0) > 1:
            bits.append(f"attempts={item['attempts']}")
        return "  ".join(bits)

    def walk(item_id, prefix, is_last, is_root):
        if is_root:
            lines.append(label(item_id))
            child_prefix = ""
        else:
            lines.append(prefix + (GLYPH_LAST if is_last else GLYPH_MID) + label(item_id))
            child_prefix = prefix + (GLYPH_GAP if is_last else GLYPH_PIPE)
        kids = children.get(item_id, [])
        for index, kid in enumerate(kids):
            walk(kid, child_prefix, index == len(kids) - 1, False)

    for item_id in roots:
        walk(item_id, "", True, True)

    if status["orphans"]:
        lines.append("")
        lines.append("orphaned leases (surfaced, never silently reaped):")
        for orphan in status["orphans"]:
            lines.append(
                f"  {orphan['item']}#{orphan['gen']} owner={orphan['owner']} "
                f"pid={orphan['pid']} expired {orphan['expired_ago_sec']}s ago"
            )
    if status["refusal"]:
        lines.append("")
        lines.append(f"REFUSAL: {status['refusal']}")
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", required=True)
    parser.add_argument("--tree", action="store_true", help="render the lineage forest")
    parser.add_argument(
        "--field", help="print one top-level status field raw, for shell consumption"
    )
    parser.add_argument(
        "--no-write",
        action="store_true",
        help="inspect without publishing status.json",
    )
    args = parser.parse_args(argv)

    status = q.refresh_status(args.root, write=not args.no_write)

    if args.field:
        if args.field not in status:
            raise q.QueueError(
                f"no such status field: {args.field} "
                f"(have: {', '.join(sorted(status))})"
            )
        value = status[args.field]
        print(value if isinstance(value, str) else json.dumps(value))
    elif args.tree:
        print(render_tree(args.root, status))
    else:
        print(json.dumps(status, indent=2, sort_keys=True))
    return q.EXIT_OK


if __name__ == "__main__":
    sys.exit(q.cli_main("queue_status", main))
