# The synthetic drain queue

A deterministic work queue for measuring **orchestration**, not model latency.
Duration is a fixed sleep inside the item, so a wave-shaped run and a
drain-shaped run over the same profile are directly comparable and cost nothing
but wall-clock.

Data lives here (`queue/`); executables live in `../scripts/`. Python files use
`queue_*.py` because `queuelib` is imported; shell drivers use `queue-*.sh`.

## Duration profiles

| Profile    | Durations                | What it is for                                                                                                                               |
| ---------- | ------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `moderate` | `[1,1,1,2,2,2,2,3,3,3]`  | The honest headline. Waves cost `max` per wave; a drain approaches `sum / K`. If the mechanic cannot beat waves here it is not worth having. |
| `severe`   | `[1,1,1,1,1,1,1,1,6,10]` | Where a drain should look dramatic: eight one-unit items behind a 6 and a 10, so one barrier costs the whole tail.                           |

A unit is `unit_ms` milliseconds (`--unit-ms`, profile default 200). The
self-test runs at 10.

`proposers` names the seeded items whose work, when performed, mints a **new**
item — the late-proposer property that waves get by accident and a drain must
get on purpose. `chain: N` makes the minted child a proposer too, N links deep,
so a chain deliberately runs into `max_lineage_depth` and the last link is
refused.

Item payloads are derived from the index, not written out, so the profile stays
small and the duration vector stays a literal (`self-test-queue.sh` T1 compares
it against the design's literal). `sum_range(a, b)` is the work; a distinct
range per item is what lets a verifier tell "worked" from "claimed and dropped".

## Run layout

`queue_init.py` materializes a run root. Nothing in this directory is mutated by
a run.

```
<root>/
  config.json          caps and knobs, plus the profile it came from
  status.json          the drain's stop condition (see below)
  items/<id>.json      one file per item -- never one shared queue file
  admits/<id>.json     the admission marker: this proposal is claimable
  claims/<id>/NNNN.json  one file per lease generation
  results/<id>.json    the answer, exclusively created
  events/*.json        one file per event, append-only by construction
```

**One file per item** (invariant L1). A shared mutable queue file is the
state-rot anti-pattern, and with N continuous claimants a read-then-write claim
on it is a TOCTOU race by construction: two workers both read "unclaimed" before
either writes.

## States

`ready` · `proposed` · `claimed` · `orphaned` · `done` · `dead`

`done` and `dead` are the only resting states. A failure either returns the item
to `ready` (attempts remain) or dead-letters it, so no item can sit in a state
that is neither claimable nor terminal.

Three facts are each derived from exactly one place, and none of them from a
mutable field two processes could both write:

- **claimed** — from the newest claim marker. Unreleased and unexpired is
  `claimed`; unreleased and expired is `orphaned`.
- **admitted** — from `admits/<id>.json`. Promotion never rewrites the item.
- **terminal** — from the item file, which for a terminal state is only ever
  written by the holder, after the result is already durable.

The rule that falls out, and that the concurrency safety rests on: **an item
file is writable only by its creator and its current holder.**

## The scripts

| Script                   | What it does                                                                                                                          |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------- |
| `queue_admit.py`         | The gate. Makes `proposed` items claimable, re-checking the depth cap.                                                                |
| `queue_claim.py`         | Atomic claim of one item. Runs the gate first by default. Empty claim exits 3.                                                        |
| `queue_init.py`          | Materialize a run root from a profile.                                                                                                |
| `queue_push.py`          | Enqueue derived work. The **script** computes the depth and refuses over-cap pushes.                                                  |
| `queue_release.py`       | Close a claim: `done`, `failed`, or `abandoned`.                                                                                      |
| `queue_status.py`        | Report the queue, publish `drained`, render `--tree`.                                                                                 |
| `queue_verify.py`        | Check a finished run against the correctness predicate.                                                                               |
| `queue_worker.py`        | Work exactly one item, then return. Not a loop.                                                                                       |
| `mutation-test-queue.sh` | Breaks one thing at a time and requires `queue_verify.py` to catch it.                                                                |
| `queue-branch.sh`        | One drain branch: re-dispatch a worker until `drained`. The shell stand-in for one `repeat` branch of the workflow's `parallel` node. |

Exit codes are shared across all of them: `0` ok · `1` error · `2` refused or
violated · `3` empty claim (not an error) · `4` item failed · `5` invariant
violation.

## Claiming is atomic, and not by `O_EXCL` alone

`O_EXCL` settles **who wins** in one kernel operation. It does not settle **what
a reader sees**: the name appears the instant `open` returns, so a concurrent
reader between the open and the write gets an empty or half-written record. Both
halves are needed here, so a claim marker is written to a temp file in its own
directory and then `os.link`-ed into place — `link(2)` fails with `EEXIST` for
every loser, and the winner's name appears already holding the whole record.

Requires a filesystem with hard links (this also happens to be the correct
primitive on NFS, where `O_EXCL` is not).

An **expired** lease is stolen atomically by the same mechanism: leases are
numbered, so N would-be stealers all race to create generation `top+1` and
exactly one wins. That steal _is_ the requeue. It is not a silent reap — the
previous holder is named in the new record and in a `claim.stolen_expired_lease`
event, and `queue_status.py` keeps reporting the orphan until then.

An abort **releases**: `queue_worker.py` handles SIGINT/SIGTERM by releasing the
claim as `abandoned`, and blocks those signals across the claim and the release
so a signal cannot land in the middle and leave a lease nobody knows they hold.
SIGKILL cannot be blocked by design; that is what the TTL and the orphan report
are for.

## Depth is a wire, not prose

A worker proposing new work supplies only `{claim, derived_from}`.
`queue_push.py` looks up the parent, sets `lineage_depth = parent + 1`, and
**rejects** a push that would exceed `max_lineage_depth`, dead-lettering it with
an explicit reason. Over-deep derivation is therefore structurally impossible
rather than prompt-discouraged.

The worker supplies neither the depth nor the payload — the payload comes from
the parent's own `proposes` declaration, so a worker can report that declared
work became real but cannot author work of its choosing (invariant L6).
`derived_from` must name the claimed item; naming some other, shallower parent
would be a way to dodge the cap, so a mismatch is refused.

Accepted work lands `proposed`, not `ready`. `queue_claim.py` runs the gate
itself before scanning, which is what lets a drain branch pick up late-proposed
work with no orchestrator turn in between. That does not weaken the separation:
the gate is a script, not the worker. A worker cannot set its own depth, cannot
admit an over-cap item, and every refusal stays on disk as a dead-lettered item
with a reason.

`queue_status.py --tree` renders the resulting forest — item, parent, depth,
answer, and what was dead-lettered at the cap.

## Termination

Two behaviors the drain depends on, and one that looks like it should work and
does not.

**1. `status.json` exists with `{"drained": false}` from the start.**
`queue_init.py` writes it while seeding. A _missing_ file evaluates to false
with only a debug-level log, and so does malformed JSON — so absent is not an
error, it is an invisible hang.

**2. `drained: true` is written in the same operation that observes the queue
empty**, because the consumer checks the flag _after_ each iteration body.
`queue_claim.py` and `queue_worker.py` both refresh the status on an empty
claim, which is the moment emptiness is observed.

`drained` requires `ready`, `proposed`, `claimed` and `orphaned` all at zero —
not merely "no ready items". Those four are exactly the states from which new
work can still appear. Pushing requires holding an unreleased claim, so any
actor able to mint work is counted in `claimed` or `orphaned`; a scan that sees
all four at zero has seen a state no actor can leave. A flag that ignored
`claimed` would go true one moment before a late-proposed child existed, and the
consumer would stop and drop it.

A zero denominator is not drained. An empty or missing `items/` reports a
refusal and leaves the flag false, because "everything finished" and "the
enumeration found nothing" are otherwise indistinguishable.

**3. `dry_threshold` is NOT a safe terminator, and is reported rather than
obeyed.** An empty claim makes the _worker_ return, never poll (invariant L5) —
there is no spin loop in `queue_worker.py` at all. What loops is the
orchestrator's re-dispatch. But retiring a branch after K consecutive empty
returns is unsafe once late-proposers exist: a branch can go empty while another
worker still holds the item whose completion will push a child, and if every
branch retired on that signal the child would be dropped. Adding the safety
condition ("and nothing is in flight") turns the check into `drained`. So
termination is `drained` plus `--max-iterations` as the backstop, and the dry
count is a statistic.

`--max-iterations` **aborts** on exhaustion. The workflow engine's
`onMaxIterations: "pause"` is a trap: resuming grants no further iterations so
it re-pauses immediately, and a paused run cannot be retried.

## Running it

```bash
scripts/queue_init.py --root /tmp/run --profile moderate --unit-ms 10
scripts/queue-branch.sh --root /tmp/run --owner w1 &
scripts/queue-branch.sh --root /tmp/run --owner w2 &
wait
scripts/queue_status.py --root /tmp/run --tree
scripts/queue_verify.py --root /tmp/run
```

`scripts/self-test-queue.sh` is the gate. It races N claimants over R
repetitions on both profiles and asserts zero double-claims with every item
terminal exactly once, then runs the **same** harness against a deliberately
non-atomic read-then-write claim and requires it to FAIL. Without that control a
passing test and a test that cannot fail are indistinguishable.

`scripts/mutation-test-queue.sh` is the other half of that claim. The self-test
proves the queue behaves; the mutation test proves the **verifier bites**, by
breaking one thing at a time in a copy of the tree and requiring the named check
to fail. Its scope limit is stated in its own header: every case runs one
branch, so it cannot reach the invariants that only exist under concurrency —
those are T4's job.

Tunable by environment: `CLAIMANTS`, `REPETITIONS`, `CONTROL_REPS`, `UNIT_MS`,
`TURN_MS`. Everything runs in a `mktemp` scratch directory; nothing reads or
writes `~/.kiro` and nothing launches Kiro.

`--strategy read-then-write` exists on `queue_claim.py`, `queue_worker.py` and
`queue-branch.sh` **only** as that control. It is deliberately broken, it warns
on stderr, and it must never be selected in a run.

## Requires

`jq` and `python3` on `PATH`. No third-party Python packages.
