#!/usr/bin/env python3
"""Release a claim: done, failed, or abandoned.

``done`` creates ``results/<item>.json`` exclusively, which is what makes "reaches a terminal state exactly once" a filesystem property rather than
a convention. A collision by a DIFFERENT holder is a double completion and is
reported as a violation (exit 5) with an ``item.double_completion`` event -- the
signature ``self-test-queue.sh``'s positive control looks for.

``abandoned`` is the abort path: it releases the lease and returns the item to
the pool without waiting for the TTL. ``queue_worker.py`` calls it from a
signal handler and from a ``finally`` block, so a SIGTERM or an exception
releases rather than orphans. Only SIGKILL and a hard machine loss can leave an
orphan, and those are surfaced by ``queue_status.py`` -- never silently reaped.

Exit codes: 0 released, 5 invariant violation, 1 error.
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
        "--outcome", required=True, choices=("abandoned", "done", "failed")
    )
    parser.add_argument("--answer", type=int, help="required when outcome=done")
    parser.add_argument("--reason", help="why it failed or was abandoned")
    parser.add_argument("--owner", help="assert the claim is held by this owner")
    args = parser.parse_args(argv)

    verdict = q.release(
        args.root,
        args.claim,
        args.outcome,
        answer=args.answer,
        reason=args.reason,
        owner=args.owner,
    )
    print(json.dumps(verdict, indent=2, sort_keys=True))
    return q.EXIT_INVARIANT if verdict.get("violation") else q.EXIT_OK


if __name__ == "__main__":
    sys.exit(q.cli_main("queue_release", main))
