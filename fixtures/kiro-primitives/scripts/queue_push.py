#!/usr/bin/env python3
"""Enqueue work derived from the caller's own claimed item.

The caller supplies ``{claim, derived_from}`` and nothing else. Everything that
could be gamed is computed here:

* ``lineage_depth`` is read off the parent and incremented by this script.
  Never by the worker -- a prompt instruction to "set lineage_depth = parent + 1"
  is prose and will drift.
* A push whose depth would exceed ``max_lineage_depth`` is REFUSED and
  dead-lettered with an explicit reason. Over-deep derivation is therefore
  structurally impossible rather than prompt-discouraged.
* The payload comes from the parent item's own ``proposes`` declaration, so a
  worker can report that declared work became real but cannot author work of
  its choosing (invariant L6).
* ``derived_from`` must name the claimed item. Naming some other, shallower
  parent would be a way to dodge the cap, so a mismatch is a refusal.

Accepted work lands in state ``proposed``, not ``ready``. It becomes claimable
only when the admission gate promotes it (``queue_admit.py``, or the gate
``queue_claim.py`` runs by default before scanning).

Exit codes: 0 accepted, 2 refused at the depth cap (dead-lettered), 1 error.
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import queuelib as q  # noqa: E402


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", required=True)
    parser.add_argument("--claim", required=True, help="claim token, <item>#<gen>")
    parser.add_argument(
        "--derived-from", required=True, help="parent item id; must be the claimed item"
    )
    parser.add_argument("--owner", help="assert the claim is held by this owner")
    args = parser.parse_args(argv)

    verdict = q.push(args.root, args.claim, args.derived_from, owner=args.owner)
    print(json.dumps(verdict, indent=2, sort_keys=True))
    return q.EXIT_OK if verdict["accepted"] else q.EXIT_VIOLATION


if __name__ == "__main__":
    sys.exit(q.cli_main("queue_push", main))
