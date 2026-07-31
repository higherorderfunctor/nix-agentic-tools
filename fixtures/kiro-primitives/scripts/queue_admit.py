#!/usr/bin/env python3
"""The admission gate: promote ``proposed`` items to ``ready``.

Proposed work is not claimable. This is the only thing that mints claimable
work, and it re-checks the depth cap on the way through -- ``queue_push.py``
already refuses over-cap pushes, so a ``proposed`` item over the cap means the
cap was lowered between the push and the admission, and the gate is where that
has to be caught.

``queue_claim.py`` runs this same gate by default before it scans, which is
what lets a drain branch admit late-proposed work with no orchestrator turn in
between. That does not weaken the separation the ``proposed`` state buys: the
gate is a script, not the worker. A worker still cannot set its own depth,
cannot admit an over-cap item, and every refusal stays on disk as a
dead-lettered item with a reason.
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
    args = parser.parse_args(argv)

    admitted = q.admit_proposals(args.root)
    print(
        json.dumps(
            {"admitted": admitted, "status": q.refresh_status(args.root)},
            indent=2,
            sort_keys=True,
        )
    )
    return q.EXIT_OK


if __name__ == "__main__":
    sys.exit(q.cli_main("queue_admit", main))
