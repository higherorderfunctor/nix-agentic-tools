#!/usr/bin/env python3
"""Atomically claim one item, or report an empty claim and return.

The claim is an exclusive create of a lease-generation marker under
``claims/<item>/<gen>.json`` -- never a read-then-write. See
``queuelib.create_exclusive_json`` for why that is a temp file plus a hard link
rather than the obvious open-with-O_EXCL. The generation number
is what makes stealing an EXPIRED lease atomic too: N would-be stealers all
race to create generation ``top+1``, and exactly one wins.

An empty claim is NOT an error and NOT a reason to poll (invariant L5): this
exits ``3`` and the caller RETURNS. Re-dispatch belongs to the orchestrator,
whose stop condition is the ``drained`` flag -- see ``queue/README.md``.
Because an empty claim is the moment the queue's emptiness is observed, the
status file is refreshed in that same operation.
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
    parser.add_argument("--owner", required=True, help="claimant name, for the lease")
    parser.add_argument(
        "--item",
        help="claim this item specifically instead of the first claimable one",
    )
    parser.add_argument(
        "--strategy",
        choices=q.CLAIM_STRATEGIES,
        default="exclusive",
        help=(
            "TEST-ONLY: 'read-then-write' is the deliberately non-atomic claim "
            "that self-test-queue.sh uses as its positive control. Never use it "
            "in a run."
        ),
    )
    parser.add_argument("--unsafe-window-ms", type=int, default=2)
    parser.add_argument(
        "--no-admit",
        action="store_true",
        help="skip the proposal-admission gate before scanning",
    )
    args = parser.parse_args(argv)

    if args.strategy != "exclusive":
        print(
            f"queue_claim: WARNING strategy={args.strategy} is deliberately "
            "non-atomic and exists only as a test control",
            file=sys.stderr,
        )

    if args.item:
        if not args.no_admit:
            q.admit_proposals(args.root)
        record = q.acquire(
            args.root,
            args.item,
            args.owner,
            strategy=args.strategy,
            unsafe_window_ms=args.unsafe_window_ms,
        )
    else:
        record = q.claim_next(
            args.root,
            args.owner,
            strategy=args.strategy,
            unsafe_window_ms=args.unsafe_window_ms,
            admit=not args.no_admit,
        )

    if record is None:
        payload = {"claimed": None, "status": q.refresh_status(args.root)}
        print(json.dumps(payload, indent=2, sort_keys=True))
        return q.EXIT_EMPTY

    payload = {
        "claim": record,
        "claimed": q.load_item(args.root, record["item_id"]),
        "token": q.claim_token(record["item_id"], record["gen"]),
    }
    print(json.dumps(payload, indent=2, sort_keys=True))
    return q.EXIT_OK


if __name__ == "__main__":
    sys.exit(q.cli_main("queue_claim", main))
