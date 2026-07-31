#!/usr/bin/env python3
"""Work exactly one item, then return. One invocation is one item.

Deliberately not a loop. Two reasons, and neither is style:

* A sub-execution that crosses its context threshold compacts, and that
  compaction truncates its PARENT session's stored history -- so long-lived
  drainer workers are ruled out on a data-corruption ground. One item per
  invocation makes every worker short by construction.
* An empty claim makes the worker RETURN, never poll (invariant L5). There is
  no spin loop here to accidentally leave running.

Re-dispatch is the orchestrator's job and its stop condition is the ``drained``
flag, never an empty claim -- ``queue-branch.sh`` is the reference driver.

Order of operations matters: work, then push, then release. ``queue_push.py``
requires a live claim, so pushing after the release would be refused, and that
is deliberate -- it is what guarantees any actor able to mint work is counted in
the ``claimed`` bucket that gates ``drained``.

Exit codes: 0 worked, 3 empty claim (dry -- not an error), 4 item failed and was
requeued or dead-lettered, 5 invariant violation, 1 error.
"""

import argparse
import contextlib
import json
import os
import signal
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import queuelib as q  # noqa: E402

ABORT_SIGNALS = frozenset({signal.SIGINT, signal.SIGTERM})


class Aborted(Exception):
    """A signal arrived. Raised so the release path still runs."""


def _install_abort_handlers():
    def handler(sig, _frame):
        raise Aborted(f"signal {sig}")

    for sig in sorted(ABORT_SIGNALS):
        signal.signal(sig, handler)


@contextlib.contextmanager
def signals_deferred():
    """Hold SIGINT/SIGTERM until the enclosed critical section finishes.

    Without this the abort story has a hole that is easy to miss and was
    measured: a SIGTERM delivered INSIDE the claim raises out of ``acquire``
    before this process has a token, so the ``except Aborted`` release below
    cannot run and the lease sits held until its TTL. Blocking makes the signal
    pend and be delivered the instant the section completes -- by which time
    there is a token to release. The same applies to the release itself, which a
    second signal must not be able to interrupt half-way.

    ``pthread_sigmask`` blocks rather than ignores, so nothing is lost. SIGKILL
    cannot be blocked by design; that path is what the lease TTL and the orphan
    report exist for.

    CONTRACT ON THE CALLER, and it is not optional: the pending signal fires
    inside this manager's ``finally``, so ``Aborted`` is raised AT THE ``with``
    BOUNDARY -- not at the next statement. Anything needed to undo the work done
    inside the block (here, the claim token) must therefore be computed INSIDE
    the block, and the ``with`` must sit inside the ``try`` that releases. Put
    either one outside and the exception escapes holding a claim nobody can
    release, which is the exact failure this function is named for.
    """
    signal.pthread_sigmask(signal.SIG_BLOCK, ABORT_SIGNALS)
    try:
        yield
    finally:
        signal.pthread_sigmask(signal.SIG_UNBLOCK, ABORT_SIGNALS)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", required=True)
    parser.add_argument("--owner", required=True)
    parser.add_argument("--strategy", choices=q.CLAIM_STRATEGIES, default="exclusive")
    parser.add_argument("--unsafe-window-ms", type=int, default=2)
    parser.add_argument("--no-admit", action="store_true")
    parser.add_argument(
        "--hold-sec",
        type=float,
        default=0.0,
        help=(
            "fixture affordance: hold the claim this long before working it, so "
            "a SIGKILL can be delivered mid-lease (orphan path) or a SIGTERM "
            "mid-lease (graceful-release path)"
        ),
    )
    parser.add_argument(
        "--simulate-failure",
        action="store_true",
        help="fixture affordance: release outcome=failed instead of working",
    )
    args = parser.parse_args(argv)

    if args.strategy != "exclusive":
        print(
            f"queue_worker: WARNING strategy={args.strategy} is deliberately "
            "non-atomic and exists only as a test control",
            file=sys.stderr,
        )

    _install_abort_handlers()
    config = q.load_config(args.root)

    # THE CLAIM LIVES INSIDE THE TRY, and the token is computed while signals are
    # still blocked. Both halves are load-bearing, and the first version of this
    # had neither -- while its docstring claimed the hole was closed, which is
    # worse than the hole.
    #
    # `signals_deferred()` blocks SIGINT/SIGTERM for the claim, so a signal
    # arriving mid-claim PENDS. It is then delivered the instant the context
    # manager unblocks -- inside `__exit__`, i.e. BEFORE control reaches the next
    # statement. So `Aborted` is raised at the `with` boundary itself. If the
    # token were computed after that boundary, and the try began after that
    # again, the exception would escape `main()` with a claim marker already on
    # disk and no token in hand to release it: the lease sits held for its whole
    # TTL and the item is invisible to the next run -- not terminal so not done,
    # still claimed so not claimable. That is precisely the failure this function
    # exists to prevent, reintroduced two lines below where it is described.
    record = None
    token = None
    released = False
    verdict = {"owner": args.owner}
    try:
        with signals_deferred():
            record = q.claim_next(
                args.root,
                args.owner,
                strategy=args.strategy,
                unsafe_window_ms=args.unsafe_window_ms,
                admit=not args.no_admit,
            )
            if record is not None:
                token = q.claim_token(record["item_id"], record["gen"])

        if record is None:
            # The moment emptiness is observed is the moment the flag is published.
            print(
                json.dumps(
                    {"claimed": None, "status": q.refresh_status(args.root)},
                    indent=2,
                    sort_keys=True,
                )
            )
            return q.EXIT_EMPTY

        item = q.load_item(args.root, record["item_id"])
        verdict = {"item": item["id"], "owner": args.owner, "token": token}
        if args.hold_sec > 0:
            time.sleep(args.hold_sec)
        if args.simulate_failure:
            with signals_deferred():
                outcome = q.release(
                    args.root,
                    token,
                    "failed",
                    reason="simulate_failure",
                    owner=args.owner,
                )
                released = True
            verdict["release"] = outcome
            print(json.dumps(verdict, indent=2, sort_keys=True))
            return q.EXIT_ITEM_FAILED

        answer = q.perform(item, config["unit_ms"])
        verdict["answer"] = answer

        with signals_deferred():
            # Push BEFORE release: queue_push refuses a released claim, and that
            # refusal is load-bearing -- it is what guarantees every actor able
            # to mint work is counted in the `claimed` bucket that gates
            # `drained`.
            pushed = None
            if item.get("proposes"):
                pushed = q.push(args.root, token, item["id"], owner=args.owner)
            verdict["pushed"] = pushed
            outcome = q.release(
                args.root, token, "done", answer=answer, owner=args.owner
            )
            released = True
        verdict["release"] = outcome
        print(json.dumps(verdict, indent=2, sort_keys=True))
        if outcome.get("violation"):
            return q.EXIT_INVARIANT
        return q.EXIT_OK
    except Aborted as abort:
        # `token is None` means the signal landed before or during the claim, so
        # there is nothing held and nothing to release. Guarding on it rather
        # than on `record` because the token is what `release` needs.
        if token is not None:
            with signals_deferred():
                q.release(
                    args.root, token, "abandoned", reason=str(abort), owner=args.owner
                )
                released = True
        verdict["aborted"] = str(abort)
        print(json.dumps(verdict, indent=2, sort_keys=True))
        return q.EXIT_ITEM_FAILED
    finally:
        if token is not None and not released:
            # An exception on any other path must not leave the lease held for
            # the whole TTL. Suppressing a failure here would mask the original
            # traceback, so the release is best-effort and says so.
            try:
                with signals_deferred():
                    q.release(
                        args.root,
                        token,
                        "abandoned",
                        reason="worker_exception",
                        owner=args.owner,
                    )
            except q.QueueError as error:
                print(
                    f"queue_worker: release-on-abort failed: {error}", file=sys.stderr
                )


if __name__ == "__main__":
    sys.exit(q.cli_main("queue_worker", main))
