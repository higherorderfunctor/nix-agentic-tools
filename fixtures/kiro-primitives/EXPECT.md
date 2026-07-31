# EXPECT.md — what a mode-F run must prove

> **Last verified:** 2026-07-31 against KAS 2.15.2 (kiro-cli 2.15.2). The
> reconstruction half was developed and measured against this machine's real
> transcript corpus; the predicate half was exercised first against synthetic
> runs whose answers are known, and **then against four live workflow runs** —
> see "What a live run has now verified" below and
> `evidence/drain-live-runs.md`.
>
> The previous marker said "no live Kiro session was started to produce any of
> it", which was true when written and is now the opposite of true. It is called
> out rather than quietly replaced because the claim it made — that the engine
> could not be driven without an operator — is the assumption this file was
> built under, and two of its predicates (`F2`, `X1`) still carry that shape.

Every predicate here is executable. `verify.py` is the implementation, this file
is the contract, and neither is allowed to drift from the other — a predicate
described here with no check id beside it is a bug in one of the two files.

```bash
./verify.py reconstruct     # rebuild the execution forest from the transcripts on disk
./verify.py check RUN.json  # evaluate every predicate against one run's state file
./verify.py self-test       # the predicates against synthetic runs whose answers are known
./verify.py mutants         # break each predicate and demand self-test notices
```

## The property that actually matters

Throughput is the visible win. The load-bearing property is that **nothing is
dropped**. A spawn that drops a queued item is a FAILURE, not "no work" — and it
is the failure mode that looks best from the outside, because a run that
silently discards half its queue finishes early and reports success.

So the predicates are ordered by how badly a violation lies to you, not by how
likely it is.

## Correctness predicates

| Id  | Predicate                                                                 | Violation signature                                                                     |
| --- | ------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| P1  | Every seeded item reaches a terminal state **exactly once**               | an item with zero terminal events that nothing carried forward, or with two             |
| P2  | Every **late-proposed** item — minted by a worker mid-run — is worked too | a late item never claimed while the loop went on claiming others                        |
| P3  | The run terminates **unattended**, every item in a legal state            | `operatorIntervened`, an illegal termination reason, or a claim never released          |
| P4  | **No item is worked twice** — the claim is atomic                         | overlapping claims, two implementations in one claim interval, any event after terminal |

Three of these need a word about what they do **not** say.

**P1 does not require finishing everything.** An item still enqueued when the
run stops on a budget is not dropped — it is residual, and residual is legal
provided the state file **names it** in `carriedForward` and the termination
reason is one that permits leftovers (`budget-exhausted`, `no-progress-guard`).
What P1 forbids is an item that is neither terminal nor named: that item has
vanished, and nothing will ever pick it up again. `queue-drained` is the one
reason that permits no residue at all, because it asserts the queue was empty.

**P2 is the property waves get by accident and a drain must get on purpose.** A
wave scheduler re-reads the queue at the top of each wave, so a mid-wave arrival
is picked up by the next wave whether or not anyone designed for it. A drain has
no such boundary, so late arrivals are exactly what it can starve. The check is
sharp rather than fuzzy: a late item may go unworked **only** if nothing else
was claimed after it was proposed. If the loop kept claiming other items and
never came back to this one, the late item was starved, and it does not matter
that the loop was busy. P2 also refuses to return PASS on a run with no late
items — that run did not test the property, and `INCONCLUSIVE` is the honest
verdict.

**P3 is about ending legally, not about ending complete.** A run that stops
because its budget ran out, with residue recorded, passes. A run that stops
because a human answered a prompt does not, and neither does one that leaves a
claim held by an execution that never released it — that item is invisible to
the next run: not terminal, so not done; still claimed, so not claimable.

## Red flags

| Id  | Flag                                                      | Why it is a flag                                                            |
| --- | --------------------------------------------------------- | --------------------------------------------------------------------------- |
| F1  | More than 3 attempts on one item with no terminal state   | the loop is retrying a thing that cannot succeed, and calling it work       |
| F2  | A verifier running in the same session as the implementer | the implementer's context is the thing being checked; sharing it defeats it |
| F3  | No state file, or one with nothing to resume from         | the loop has amnesia every run                                              |
| F4  | Notifications on every run                                | a notification that always fires carries no signal, so nobody reads it      |

F2 and F4 both refuse to say PASS on an empty denominator. If no item was both
implemented and verified, F2 is `INCONCLUSIVE` — separation was never exercised.
If fewer than two runs have been observed, F4 is `INCONCLUSIVE` — "every run" is
not yet a measurable statement. A green F4 on a one-run history would be
indistinguishable from a broken F4.

## The cross-check, which is the real point

Two independent views of the same run must agree.

1. **The lineage forest** — domain-level and authoritative. Rendered from the
   queue: every item with its parent and depth, plus the executions the
   scheduler believes it dispatched and who dispatched each.
2. **The reconstructed call graph** — execution-level and post-hoc. Rebuilt from
   the transcripts on disk after the run, from files the scheduler does not
   write.

`X1` compares the two **edge sets**, not just their sizes, so a disagreement
localizes to a specific worker instead of a count. Worker count and nesting
depth fall out of that comparison, and each is reported separately when it
differs, because the two failures mean different things:

- an edge the queue believes in that no dispatch row records → the work was
  dropped, **or** the queue recorded the wrong dispatcher
- an edge on disk the queue does not know about → a worker ran untracked
- depth disagreement → the parent relation itself is wrong, which is the
  display-collapse signature below

This is a stronger signal than either view alone, and it is the honest answer to
the fact that the interactive display **collapses** a completed dispatch node
into a summary counting only DIRECT children — so a grandchild appears
root-spawned. **Reconstruct from transcripts, never from the display.**

### `parentExecutionId` is NOT the nesting edge

This is the single most expensive thing to get wrong here, because getting it
wrong produces a tree that agrees with the display — and agreement feels like
confirmation.

Measured over this machine's corpus, 2026-07-29 to 2026-07-30:

- For **7 of 7** nested dispatchers, the `parentExecutionId` on the nested
  dispatch row is **identical** to the `parentExecutionId` on the root dispatch
  row that created that dispatcher. It names the root turn's execution, not the
  immediate parent.
- Across the whole corpus, **0 of 617** child execution ids ever appear as a
  `parentExecutionId`, and **5 of 5** `parentExecutionId` values found in child
  transcripts also appear in root transcripts. The field cannot express nesting
  at all.

So a forest built from that field is flat by construction. The only nesting edge
on disk is **which file the dispatch row lives in**:

- a `sub_agent_start` row in `<session>/messages.jsonl` → the dispatcher is the
  root session
- a `sub_agent_start` row in `<session>/sub-executions/<X>.jsonl` → the
  dispatcher is execution `X`

`verify.py reconstruct` computes **both** forests and prints both depths, so the
naive method's flattening stays visible as a control (`C5`) rather than becoming
a bug someone reintroduces. On the real corpus the naive method reaches depth 1
where the correct method reaches depth 2; if those two ever agree on a corpus
containing nested dispatch, either the field changed meaning or the
reconstruction regressed, and `C5` fails rather than quietly passing.

### A workflow run has no dispatch rows at all — `X1` needs a different second view

Measured 2026-07-30 against KAS `2.15.2-7755e465…`, on the first two live
workflow runs ever made on this machine.

A workflow **step is a top-level session**, not a sub-execution. The engine
creates each step's session beside the parent chat session in the same bucket
and records it in the workflow's own tracker; it does **not** emit a
`sub_agent_start` row anywhere. Reconstructing the two smoke runs found 3
sessions, 68 transcript rows, and **0 dispatch rows** — so every downstream
figure was vacuous and `reconstruct` correctly returned `INCONCLUSIVE` on `C0`.

That is not a reconstruction bug and it is not fixable by reading more files.
`verify.py reconstruct` rebuilds the forest from subagent **dispatch** rows,
which is the right and only edge source for `invoke_sub_agent` fan-out. A
workflow drain does not fan out that way, so **`X1` as written can never be
anything but `INCONCLUSIVE` for the workflow arm** — and, worse, it would be
INCONCLUSIVE for a _correct_ run and an _incorrect_ one identically.

The workflow arm's second view is on disk in a different place:

```
<home>/.kiro/sessions/<bucket>/workflows/<workflowId>/
  workflow-definition.json   the definition as the engine parsed it
  sessions.json              {nodeId, nodePath, sessionId} per step session
  workflow-state.json        the node tree with per-node status and sessionId
```

`sessions.json` is the tracker the engine appends to as each step session
starts. Measured over the K=5 drain run — 19 step sessions — each entry carries
exactly `{iteration, nodeId, nodePath, sessionId}`:

```json
{
  "iteration": 0,
  "nodeId": "shard-01-item",
  "nodePath": [
    "wf_87d18b666ac1857b",
    "drain",
    "shard-01",
    "iter-0",
    "shard-01-item"
  ],
  "sessionId": "sess_ff7f0a7a-c099-437e-8dde-f0a1ee28f3dd"
}
```

**Branch identity is in `nodePath`, not in a `branchId` field.** The emitter
does spread a `branchId` when one is defined, so the field is real — but for the
drain's shape (a `repeat` per branch under one `parallel`) it was absent from
all 19 entries, and the branch is instead the `nodePath` segment before the
`iter-N` one. Read the path; do not look for the field and conclude the run was
not branched. That `nodePath` + `iteration` + `sessionId` triple is the edge set
to diff the queue's beliefs against, and the engine writes it rather than the
scheduler under test, which is the property `X1` actually needs. The step
sessions' own transcripts are then reachable by `sessionId` in the ordinary way.

**Do not substitute the notification stream for this.** `node_start` carries the
same triple and arrives live, which makes it the right source for _timing_ — but
it is a stream this driver could drop, and a view that shares a failure mode
with the thing it is checking is not an independent view.

## Reconstruction rules

Two enumeration rules, both load-bearing:

1. **Exclude the legacy v2 store.** It is a sibling bucket literally named
   `cli`, and it also contains `sess_<uuid>.history` files — so a `sess_` prefix
   alone does not mean v3. Only 16-hex bucket names are accepted, and every
   rejected bucket is reported **by name**, so a renamed store shows up as a
   skip instead of silently reducing the denominator to zero.
2. **Do not assert an exact set of entries in a session directory.** A
   `tool-outputs/` directory appears lazily, whenever some tool returns a large
   payload. "These exact entries exist" is a test that passes until it doesn't.
   (None exist on this machine today; that is a snapshot, not an invariant.)

And one reader rule that cost a wrong conclusion to find:

3. **Do not split transcripts with `str.splitlines()`.** It breaks on U+0085,
   U+2028, U+2029, `\x0b`, `\x0c` and `\x1c`–`\x1e`, not only on newline.
   Transcript rows quote raw tool output, and **2 of 88005** records on this
   machine contain U+0085 inside a string — one of them a single 4.7 MB record.
   A `splitlines()` reader cuts each of those into 23 fragments, drops 2 real
   records, and reports 44 parse failures that do not exist. That was my first
   reading of this corpus and it was wrong: the same census shows **0 of 88005**
   records span a real newline, so the engine does honour one record per line.
   `verify.py` parses by value with `raw_decode`, which survives both hazards,
   counts each hazard class separately, and matches `jq`'s record count exactly.

**Every count carries its denominator, and every measurement over live state
carries when it was taken.** "Zero nested dispatches" means nothing without "and
N dispatch rows are present in the same files" — otherwise absent and
not-instrumented are indistinguishable. The figures in this file are
live-drifting: re-measure, never hardcode.

## The run-state contract

The loop must write one JSON file per run, schema `kiro-mode-f/run/1`. Keys are
sorted; `verify.py` requires `carriedForward`, `events`, `executions`, `items`,
`notifications`, `runId`, `schema` and `termination`, and treats a missing key
as `F3` rather than as a crash.

```json
{
  "carriedForward": ["item-e"],
  "events": [
    {
      "execution": "<uuid>",
      "item": "item-a",
      "kind": "claim",
      "seq": 1,
      "session": "sess-a"
    },
    {
      "execution": "<uuid>",
      "item": "item-a",
      "kind": "implement",
      "seq": 2,
      "session": "sess-a"
    },
    {
      "execution": "<uuid>",
      "item": "item-b",
      "kind": "propose",
      "seq": 3,
      "session": "sess-a"
    },
    {
      "execution": "<uuid>",
      "item": "item-a",
      "kind": "verify",
      "seq": 4,
      "session": "sess-b"
    },
    {
      "execution": "<uuid>",
      "item": "item-a",
      "kind": "done",
      "seq": 5,
      "session": "sess-a"
    }
  ],
  "executions": [
    { "dispatchedBy": null, "id": "<uuid>", "role": "implementer" },
    { "dispatchedBy": "<uuid>", "id": "<uuid>", "role": "verifier" }
  ],
  "items": [
    { "id": "item-a", "origin": "seed", "parent": null },
    { "id": "item-b", "origin": "late", "parent": "item-a" }
  ],
  "notifications": {
    "runsObserved": 4,
    "runsWithNotification": 1,
    "thisRun": 0
  },
  "runId": "<opaque>",
  "schema": "kiro-mode-f/run/1",
  "sessionDir": "/home/<user>/.kiro/sessions/<16-hex bucket>/sess_<uuid>",
  "stampedAt": "2026-07-30T00:00:00Z",
  "termination": { "operatorIntervened": false, "reason": "queue-drained" }
}
```

Field notes, only the ones that are easy to get wrong:

- `events[].seq` must be a **total order** over the whole log — duplicates are
  reported, because overlap detection has no meaning without one. `kind` is one
  of `abandoned`, `claim`, `done`, `failed`, `implement`, `propose`, `release`,
  `verify`.
- `events[].execution` is the sub-execution uuid that did the thing;
  `events[].session` is what `F2` compares. They are separate on purpose: two
  executions can share a session, and that is precisely the F2 failure.
- `executions[].dispatchedBy` is `null` for a worker dispatched by the root
  session, otherwise the dispatching execution's uuid. **This is the field `X1`
  checks against disk**, and writing the root turn id here — the thing
  `parentExecutionId` actually holds — is the mistake that reproduces the
  display's collapse inside the state file. `verify.py self-test` has a case for
  exactly that (`cross-flattened`).
- `items[].origin` is `seed` or `late`; a `late` item must carry a `propose`
  event and a `seed` item must not.
- `sessionDir` is what makes `X1` possible. Omit it and `X1` is `INCONCLUSIVE`,
  never PASS.

### The seed-placement interaction

A mis-placed seed **fails silently**: `session/load` of an unknown id hydrates a
fresh session with the workflow flag OFF, writes it over the path, and logs
`session.load.create_uncreated`. The run then does no dispatch at all. That
presents to `X1` as **zero edges on both sides**, which is reported
`INCONCLUSIVE` rather than PASS — agreement between two empty views is vacuous.
Confirm the bucket with `harness/self-test-bucket.sh` before the run, and
confirm the session root from the engine's own `Initializing persistence at` log
line rather than inferring it. A schema-invalid seed fails loud instead
(`CORRUPTED_DATA`) and is invisible in session listings.

## Verdicts and exit codes

| Verdict        | Exit | Meaning                                                      |
| -------------- | ---- | ------------------------------------------------------------ |
| `FAIL`         | 1    | at least one predicate was violated                          |
| `INCONCLUSIVE` | 2    | nothing was violated, but at least one denominator was empty |
| `PASS`         | 0    | every predicate held over a non-empty denominator            |

`INCONCLUSIVE` is deliberately not success. A predicate that could not have
failed did not pass.

## What a live run has now verified

Measured 2026-07-31 against KAS `2.15.2-7755e465…`; figures and method in
`evidence/drain-live-runs.md`.

- **P1–P4 all PASS on both duration profiles**, over a real K=5 drain against
  the shared synthetic queue — 16 items on `moderate` (6 of them late-proposed,
  none starved) and 13 on `severe`, every one terminal exactly once, both
  terminating unattended on `queue-drained` with nothing carried forward.
- **P4 FAILS on a deliberately misconfigured run**, and names the two step
  sessions that held one item concurrently. That is the predicate biting on real
  data rather than on a synthetic mutant, and it is the same run in which `P1`
  passes — the item reached exactly one terminal state, `dead`. An item can be
  fully accounted-for and worked twice at once, which is the argument for
  keeping the predicates separate. Cause and fix: C-19.
- **F2 and X1 remain `INCONCLUSIVE` by construction**, not by accident. The
  synthetic queue has no verifier role, so nothing is ever both implemented and
  verified; and a workflow run emits no dispatch rows, so X1 has no disk-side
  edge set. Both are reported, neither is claimed as PASS.
- **The attribution join is the cross-check that does apply**, and it found **0
  misses over 142 queue actions across three runs**. See the `X1` subsection
  above for why it, rather than the transcript forest, is the right second view
  on this arm.

## What has been verified without a live run

- **The reconstruction, over the real corpus.** 216 sessions scanned, 46
  dispatching, 617 dispatch rows, 616 child transcripts, max depth 2 by the
  correct method and 1 by the naive one. Corroborated independently by a `jq`
  pass over the same files that agrees on all nine figures it can compute.
- **One real anomaly, found rather than assumed.** One dispatch of 617 recorded
  a Bedrock tool-use id as its `subSessionId` instead of a session uuid, has no
  `sub_agent_complete`, and never wrote a transcript. It is a genuine dropped
  dispatch sitting in the live corpus — the exact shape `X1` exists to catch —
  and the reason `verify.py` does not assume child ids are uuids.
- **The predicates, over synthetic runs.** 78 assertions: the good run must pass
  **every** check with no empty denominators, and each broken run must fail on
  the named check **and for the named reason**. The reason assertion is not
  decoration: the first draft of the double-work fixture tripped `P4` via
  claim-after-terminal instead, so it was green while testing the wrong bug.
- **The self-test itself, by mutation.** 21 mutations, each breaking one piece
  of predicate logic; all 21 make `self-test` exit non-zero. That run is what
  found two genuinely unverified checks — C2's orphan detection and one arm of
  the X1 edge diff were both deletable with the self-test still green — and both
  gained a fixture.

## Staleness triggers

Update this file **in the same commit** as any of these:

- `parentExecutionId` starts naming the immediate parent (then `C5` flips to
  FAIL and the edge rule can be simplified — verify, do not assume)
- `sub-executions/` starts nesting by depth, or child transcripts move out of
  the root session's directory
- the dispatch row's discriminator (`subExecutionId`) or relationship fields
  (`subSessionId`, `parentExecutionId`) are renamed
- the legacy store stops being a bucket named `cli`
- the run-state schema changes shape — bump `kiro-mode-f/run/1` and update both
  files
