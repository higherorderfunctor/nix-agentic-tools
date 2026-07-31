# Evidence — the drain, run live

> **Measured 2026-07-31** against KAS
> `2.15.2-7755e465057ad864a83fb445dbc6bfc63e77c5f2837adcb4a37913965ced7a8e`
> (kiro-cli 2.15.2), under a scratch `HOME` with `XDG_DATA_HOME` left real.
> Every figure below is live and re-measurable — re-run, never hardcode.

This is the first mode-**F** evidence in the corpus. Until now every record here
was a code read or a measurement over pre-existing files; these are runs that
were started, watched and read back.

## What was established

**The engine runs a workflow headless.** `_kiro/workflow/new` → `invoke` → poll
`inspect`, over ACP on stdio, with no TUI, no seeded session, no workflow
feature flag and no operator. The unadvertised extension methods are not merely
reachable (already known) but **drivable to completion**. `harness/acp-drain.py`
is the driver; it answers the engine's auth callback and its permission
requests, and records the lifecycle notification stream.

**Branches refill independently — there is no barrier between iterations.** The
only join is the final one.

**The predicates hold on live data.** P1–P4 all PASS on both duration profiles,
and P4 FAILS on a deliberately misconfigured run, naming the two step sessions
that overlapped.

> **Read that last claim as PROVISIONAL, and here is the exact reason.** Every
> other verifier in this harness had to demonstrate it _rejects_ something
> before its green result was accepted — the queue verifier against 6 mutations,
> `verify.py` against 21, the workflow validator against 79 negative cases.
> `harness/emit-run-state.py`, which decides what the predicates even see, has
> **no such test**. So a defect in it would most plausibly present as P1–P4
> passing, which is indistinguishable from the result above.
>
> The P4 FAIL on the misconfigured run is the one piece of independent support:
> the same emitter produced a run state that made a predicate bite, which a
> uniformly broken emitter could not do. That is weaker than a mutation suite
> and is not offered as a substitute for one.

## The runs

| Run                 | Profile  | Items | Outcome                | Wall  |
| ------------------- | -------- | ----- | ---------------------- | ----- |
| shard drain         | —        | 15    | completed, 15/15 right | 71 s  |
| queue drain         | moderate | 16    | drained, P1–P4 PASS    | 66 s  |
| queue drain         | severe   | 13    | drained, P1–P4 PASS    | 56 s  |
| queue drain, broken | severe   | 13    | **P4 FAIL**, 1 dead    | 126 s |

K = 5 branches, `joinPolicy: "allSettled"`, `onMaxIterations: "abort"`,
`modelId: "auto"`, `effortLevel: "low"`, `unit_ms = 3000` on every queue run.

## Independent refill, from the engine's own notifications

The shard drain's `node_start` / `loop_iteration` stream, abridged. Read the
iteration numbers against the clock:

```
 31.72  shard-03 enters iteration 2
 34.14  shard-04 enters iteration 2
 34.45  shard-05 enters iteration 2
 37.41  shard-01 enters iteration 2   <- 5.7s after shard-03 did
 52.25  shard-02 stops (drained)
 66.08  shard-04 stops (drained)      <- 13.8s spread across branches
```

Branches sit at **different iteration indices at the same wall-clock moment**
and terminate 13.8 s apart. A wave scheduler cannot produce that shape: its
whole definition is that no branch starts round N+1 until every branch has
finished round N.

## Throughput, against the wave counterfactual

The counterfactual is computed from the engine's own per-step windows in
`workflow-state.json`: a wave pays, per round, the duration of that round's
**slowest** branch. Same steps, same durations, reordered by the barrier a wave
would impose.

| Profile              | Serial  | Wave   | Observed | vs serial | saved vs waves |
| -------------------- | ------- | ------ | -------- | --------- | -------------- |
| shard (uniform work) | 293.5 s | 73.2 s | 71.0 s   | 4.13x     | 3 %            |
| queue `moderate`     | 294.8 s | 68.9 s | 66.0 s   | 4.47x     | 4.2 %          |
| queue `severe`       | 254.0 s | 82.7 s | 56.0 s   | 4.54x     | **32.3 %**     |

**The near-zero rows are the point, not a disappointment.** Where every item
costs about the same, a round's slowest branch is also its average, so a barrier
costs almost nothing and a drain has almost nothing to win. `severe` puts a
6-unit and a 10-unit item behind eight 1-unit items, and there the barrier costs
a third of the run.

So "a drain beats waves" is **conditional on duration variance**, and quoting a
single speedup number without the profile it came from is meaningless. A uniform
workload does not need this mechanic.

The `4.1–4.5x` column against a ceiling of K=5 is the concurrency actually
achieved, and it is the honest ceiling check: the missing 0.5–0.9x is startup,
the tail where branches run out of work at different times, and per-step
overhead.

## Attribution — the cross-check that does apply here

The queue attributes work to a **branch label**; the engine records a **session
id** per iteration. Neither knows the other's identity.
`harness/emit-run-state.py` joins them by time: a claim by `branch-03` at time T
belongs to the one `branch-03` step session whose `[startedAt, endedAt]` window
contains T.

**0 attribution misses across all three queue runs** (54, 42 and 46 queue
actions). Every claim, result and push landed inside a window the engine
recorded independently. A miss would mean a worker acted outside any execution
the engine knows about.

This stands in for `X1`, which cannot run on this arm at all — see EXPECT.md:
workflow steps are top-level sessions, so there are no `sub_agent_start` rows to
diff against, and `verify.py` correctly reports `INCONCLUSIVE` rather than
manufacturing agreement between two empty sets.

## Cost of the fixtures

25 step executions for `moderate`, 20 for `severe`, 53 for the broken run — one
model turn each, at `effortLevel: low`. The broken run's 53 is itself the tell:
it re-worked a 30 s item three times. Permission requests are answered by the
driver (25, 20 and 53 respectively); none was left unanswered, and an unanswered
request does not fail, it **hangs**.

## Re-running

```bash
cd fixtures/kiro-primitives
eval "$(./harness/scratch-up.sh)"
./scripts/queue_init.py --root "$KIRO_FIXTURE_WORKSPACE/.kiro-harness/queue" \
  --profile severe --unit-ms 3000 --lease-ttl-sec 90
./harness/acp-drain.py --parent-session \
  --home "$KIRO_FIXTURE_HOME" --workspace "$KIRO_FIXTURE_WORKSPACE" \
  --definition workflows/drain-queue.workflow.json \
  --input scripts_dir="$PWD/scripts" --out /tmp/run.json
./harness/emit-run-state.py --queue-root "$KIRO_FIXTURE_WORKSPACE/.kiro-harness/queue" \
  --workflow-dir "$KIRO_FIXTURE_HOME/.kiro/sessions/<bucket>/workflows/<workflowId>" \
  --drain-record /tmp/run.json --out /tmp/RUN.json
python3 verify.py check /tmp/RUN.json
```

`--lease-ttl-sec 90` is not optional at this unit and `queue_init.py` now
refuses without it — see C-19, which is the reason the ceremony exists.

## Preconditions that bite

- **The machine must be logged in to Kiro.** `XDG_DATA_HOME` stays real by
  design; an empty credential store makes the CLI open a browser rather than
  fail.
- **The token is not refreshed by this harness, by ruling.** It is read from the
  operator's store, and the driver refuses to start with under 8 minutes left.
  The CLI renews only once the token has actually **expired** — `whoami` before
  expiry does not refresh — so a long battery needs the run scheduled against
  that cycle rather than against a wall clock.
- **The wrapper cannot reach `acp`.** `ai.kiro.tui = true` appends `--tui --v3`
  unconditionally and the `acp` subcommand rejects both; the driver resolves the
  real binary out of the wrapper's `exec` line. That is a repo defect, not a
  harness one.
