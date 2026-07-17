# living-workflow-backlog — the backlog sub-workflow

The place to **dump feedback on the living-plan _workflow itself_** — not on any downstream
project. This is a **living plan** (it has its own `state.json`) but a special kind: a perpetual
**rolling backlog**.

It is a **sub-workflow of the living workflow** — a perpetual rolling backlog. Every session
running under a living plan reflects at close and drops sanitized, generalized improvement
candidates here, and a **grooming session** drains them by **folding** each tuning into the doc it
targets. The nesting model (sub-workflow vs. downstream child plans), the two-channel backlog
terminology, the inline-fold rule, and the never-off-ramp / perpetuity semantics are owned by the
master's REFLECTION MODE / BACKLOG TERMINOLOGY / nesting sections — this doc follows them and does
not restate them.

## This is the FRAMEWORK channel, not a plan's own backlog

Per the master's BACKLOG TERMINOLOGY, "backlog" names two different things. A running plan tracks
its **own** new work in its **own** `open_items` (the plan-local channel). THIS
`living-workflow-backlog` is the **framework channel** — the collector of tuning candidates for the
living workflow **itself**, and the sole authorized editor of the living workflow (via grooming). A
plan submits framework candidates here.

## DRY-by-reference: this doc adds only what is backlog-specific

The **general living-plan protocol** — reflection mode, the entry contract, the entry lifecycle,
commit-ownership, nesting, the state substrate, state-over-tokens — lives **once** in the master
living doc (`../living-workflow/living-plan-bootstrap.md`) that every living plan references. This
doc does **not** restate it; it references it and adds only what is unique to the backlog
sub-workflow: **the grooming loop**, plus a few operational specifics (the capture/grooming split,
git posture). The shared harness (`../living-workflow/state.schema.json`) sits beside the master, and the
master's convention-delta changelog lives beside the master doc (`../living-workflow/changelog.md`);
`state.json`'s `living_doc_baseline` pins the exact master-doc commit this backlog is authored
against.

Keeping this doc a **reference, not a duplicate** of the master is a session-close invariant:
whenever this doc or the master is edited, close validates that the two stay internally consistent
and that nothing owned by the master has been copied down here.

## What lives here

Location encodes durability (master's STATE SUBSTRATE): committed durable knowledge lives in this
directory; per-worktree working state lives in the gitignored working dir under `<WORKTREE_ROOT>`.

| Path                                                                   | Role                                                                                                                                              |
| ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| `living-workflow-backlog.md`                                           | **Committed.** This grooming index — the durable explainer of the backlog sub-workflow and grooming loop.                                         |
| `<WORKTREE_ROOT>/.living-workflows/living-workflow-backlog/state.json` | **Gitignored working state.** This plan's own state (reflection_mode, ecosystem, `living_doc_baseline`, decisions, the register in `open_items`). |
| `<WORKTREE_ROOT>/.living-workflows/living-workflow-backlog/journal.md` | **Gitignored working state.** Append-only WAL narrative (may carry work detail — never committed).                                                |
| `<WORKTREE_ROOT>/.living-workflows/living-workflow-backlog/entries/`   | **Gitignored working captures.** One markdown file per candidate — never committed (may carry work detail).                                       |

The bootstrap creates the working dir (and `entries/`) if missing; there is no committed
placeholder. There is no rendered status board and no status file.

## Resuming this backlog

Resume from the **files alone** — nothing needs to carry over from a chat handoff. Read, in order:
`state.json` (current_position, reflection_mode, ecosystem, decisions, the register in
`open_items`), then this index. `current_position.next_action` is the authoritative steer; the
register is the live truth. Grooming folds inline — there is no separate adoption plan to resume
into.

## The grooming loop

A grooming session is the backlog's own processing loop. Its **goal is to FOLD**, not merely to
mark entries groomed: `GROOMED` is a transient state, and folding a tuning **removes its entry**
(the fold **is** the drain). A pass that ends with everything groomed and nothing folded has
deferred the actual point of grooming.

1. **Cold start + reconcile.** Read the pending register from state, then scan the working
   `entries/` for files not yet registered (capture writes only the file — see below) and register
   them, so the register honestly reflects what has been captured.
2. **Evaluate each entry as a request, not an order** — a fair, honest, adversarial peer. Fan **one
   subagent per entry** to keep eval load off the main session. Beware bucket collapse: if each
   evaluator is told to "default to bucket X when unsure," nearly everything lands in X and the
   split the fan-out was meant to produce is lost. Give each bucket **explicit positive criteria**,
   require a **confidence / soundness signal** alongside the label, and have the **orchestrator
   re-derive** the split from those signals. A run where every item lands in one bucket is a smell
   to re-derive, not a result.
3. **Classify each entry's fold target:** the **general protocol** (master living doc) or the
   **backlog sub-workflow's own rules** (this doc). Feedback can target either, and the target
   decides which doc the fold edits.
4. **Present under the decision-scope filter** (defined in the master). Auto-disposition the items
   the orchestrator can stand behind and surface them as one **batch for veto-by-exception**;
   reserve the **one-at-a-time** HITL walk for genuinely low-confidence, intent-dependent, or
   ground-rule-changing items.
5. **Fold each accepted tuning inline** into its target doc, obeying the master's leak-safe fold
   rule (the entry contract): write a self-contained generic tuning + generic reasoning and no
   entry/artifact references. Then **drain** the entry: remove it from the register, delete its
   file, and — for a fold that changes MASTER/harness conventions — append a **generic
   convention-delta line** to the co-located changelog (beside the master); a fold that tunes
   only this backlog doc's own rules is **git-history-only** (no dependent pins to it), and a DROP
   changes no convention (working journal only).
6. **Journal + persist each disposition the instant it is made**, so a mid-loop handoff resumes
   from state + the working journal without regenerating anything.
7. **Before closing, run the light-fix sweep** — after every OTHER substantive entry is disposed and,
   when the gated commit-readiness review is eligible this pass, immediately BEFORE it (so the review
   sees the swept, settled body — a review of a still-moving body is wasted): drain the
   consistency-nit collector through the lighter path defined below. This is a grooming step, **not**
   reflection-at-close.

A grooming session, like every session, **reflects at its own end** — but it only **buffers** any
new candidates as entries for the NEXT pass; it never self-grooms them (the session is spent). See
the master's REFLECTION MODE.

### The light-fix path for consistency nits

Not every finding earns the full grooming machinery. **Consistency nits** — a cross-reference whose
wording drifted from its target, a schema field with no prose consumer, an enumeration missing a case
its sibling has, a term used before the vocabulary defines it, a rule restated where DRY makes one
surface the owner — are **non-blocking** by the master's CONVERGENCE criterion, have exactly one
correct fix, and need no judgment. Running the full evaluate → classify → present → fold → changelog
cycle on a drifted cross-reference is wildly over-weight. They take a lighter lane that still
**collects and still fixes** them — so the population stays bounded-small — while skipping the
ceremony.

**Admission test (the whole guardrail).** A finding takes the light path ONLY if its fix is
**mechanical AND behavior-neutral**: exactly one correct fix, and applying it changes no instruction's
meaning for any reader. In scope — repoint an imprecise/dangling reference to its target; add a missing
description to a field with no prose consumer; complete an enumeration to match its sibling **when
that sibling is the unambiguous reference** (not a coin-flip between two drifted copies); harmonize
a term to the doc's established vocabulary; delete a redundant restatement **when DRY-by-reference
makes the owning surface unambiguous**. Excluded, escalate to full grooming — the moment the fix
requires **choosing which of two drifted copies is canonical**, **changes what a rule instructs**, or
resolves a contradiction **where both sides have live consumers**. **When in doubt it is a candidate,
not a nit** — the bias toward full grooming is deliberate, because a confident WRONG fix is this
workflow's demonstrated failure mode. (This behavior-neutral-vs-behavior-changing line is an instance of the master's
REPOINT-VS-MIGRATION change-class rule under VALIDATION-ON-UPDATE — the general taxonomy that rule
states, applied to a light-fix admission decision.)

**Collection.** Spotted nits accrue in a **single standing collector** — a working file
`consistency-nits.md` beside the journal in the gitignored working dir (**not** an `entries/` file, so
a cold-start reconcile never mistakes it for a candidate), the way a parked entry accrues sightings,
and **never one file per nit** (that would just move the unbounded-rounds problem into the register).
Any session may **append** a spotted nit (capture-only, per the capture/grooming split); an on-sight
fix made while a surface is already open (below) may skip the collector entirely and is recorded only
in the journal. The collector is a perpetual fixture — **empty is its normal resting state** and, per
the DRAINED gate below, it does not block convergence. It has no committed placeholder; it is created
on first append, like the working dir.

**Fixing — two arms, both grooming-session-only:**

- **Opportunistic (broken-windows):** while disposing any entry, if the groomer already has a surface
  open and spots a drifted reference TO it, fixing inline is in scope — zero marginal context cost —
  subject to the same checking as any light fix (below), and journaled.
- **Sweep:** loop step 7 — after every OTHER substantive entry is disposed and BEFORE the session's
  own close/reflection, and BEFORE the gated commit-readiness review when that review is eligible this
  pass (the review is the true LAST action and must see the swept body). It runs the collector down:
  verify each nit against source, apply the behavior-neutral fix, re-grep **with a positive control**
  to confirm the drift is gone and nothing was corrupted, journal, drain the fixed line.

The sweep is a **grooming step, not reflection-at-close**, and **never fires in a non-grooming
session** — a session at its end only BUFFERS (master REFLECTION MODE); one that spots a nit appends it
to the collector and moves on. What gets lighter is the **ceremony** — the adversarial eval, the HITL,
and the changelog line — **never the checking**: EVERY light fix, by either arm, verifies against
source before and re-greps with a positive control after, because a light fix that trusts a
false-clean is worse than the nit. Light fixes are **git-history-only**: they change no dependent-facing convention, and a
changelog line for a typo fix would itself be a fresh drift surface.

### PARK WHAT IS PLAUSIBLE BUT NOT YET DECIDABLE

FOLD and DROP are not the only honest verdicts. A candidate that is plausible but whose evidence is
a **single sighting** is decidable by neither: folding it writes a rule from one data point, and
dropping it destroys the only record that the thing was ever seen. Park it as
**`NEEDS-EVIDENCE:<what-would-decide-it>`** instead — the entry states, up front, the observation
that would settle it either way, and it accrues sightings across passes until it does.

Park on this test, not on taste. Ask what the candidate COSTS while it sits unfixed. Where the
failure is **benign and self-announcing** — it wastes no work, and whoever hits it notices
immediately — the cost of waiting is near zero and the cost of a premature rule is real, so park it
and let recurrence make the case. "Self-announcing" is judged WITH the standing mitigations in
force: a failure that announces itself only because a standing discipline catches it (a control run,
a routine check) is self-announcing ONLY while that discipline holds — its residual cost is the
attention that discipline spends each time, not literally zero — and a failure with no guaranteed
observer is **silent**, not self-announcing. Where the failure is **silent, or burns work before
anyone notices**, waiting is NOT free and the item is not a parking candidate. When a parked item
recurs enough to clear its own stated bar, the answer is often not a written rule at all but a
**tool** that makes the failure impossible or loud: where the property a rule would check is
mechanically decidable and the failure keeps recurring, prefer the tool over prose — a rule a tool
could reliably enforce is better delivered as that tool.

A parked entry stays in `entries/` and in the register, and each recurrence appends a sighting to it
rather than opening a duplicate.

### DRAINED does not mean the directory is empty

The loop runs until the backlog is **drained**, and a **parked (`NEEDS-EVIDENCE`) entry does not
count against drained** — it is waiting on the world, not on a groomer, so an indefinite hold must
never block the loop from converging. Likewise an entry whose whole job is to **run a review of
this workflow** does not count against itself.

So drained means, by property: **no entry remains that active grooming can act on now** — parked
(`NEEDS-EVIDENCE`) entries wait on the world and the gated review waits on drainedness itself, but
the gate is that property, not a fixed list of exceptions, so anything a groomer cannot act on now
likewise does not count and an indefinite hold can never block convergence. That is the
gate a review-and-commit entry waits for — it is the LAST thing to run, only once active grooming
has stopped raising new work, because reviewing a body that is still moving wastes the review.

"Raising new work" is scoped to **blocking findings and substantive candidates**, per the master's
CONVERGENCE criterion: a non-blocking consistency nit is serviced by the light-fix path above, and
the standing collector that holds it — like a parked entry — does not count against drained. So the
gate releases on **no blocking findings**, not on a directory scrubbed of every polish nit; that is
exactly what stops a review waiting forever on a body that only ever accretes nits.

## Capture vs grooming (who writes what)

Capture and bookkeeping are split. A session that is merely **proposing** a tuning (any session, at
close) only **adds the entry file** to the working `entries/` — it does **not** touch the register.
The dedicated **grooming session owns** the register: it reconciles unregistered files, manages
dispositions, folds, and drains.

So the entry **files** are authoritative for **pending (un-groomed) capture**, and the register is
the grooming session's working view reconciled from them. The durable-record and transience
semantics — the folded tuning plus its changelog line is the record, the entry is removed on fold —
are the master's entry contract, not restated here. (Web/no-repo mode has no files; the master
defines how it tracks in the doc and drains to files on the first CLI session.)

## Git posture (soft guardrails, not a hard gate)

Working state is gitignored by location (`.living-workflows/`), so entries, the journal, and
`state.json` are **never committed** — an entry can carry sensitive or in-progress work material
even though the contract forbids specifics. Commit only the **committed** surfaces: the generic
folded tunings (in their target docs), this index, and the changelog. Beyond that, a **soft hygiene
practice**: scrub specifics on the way in, and when in doubt **defer the commit** until grooming
has sharpened or folded the entry. This is a review habit and a stated default, **not** an
automated gate.

## The register and the changelog

The live register (`state.json.open_items`) is bounded to **active** candidates: when an entry
reaches a terminal disposition it drains out. That bound is the only register rule this doc owns.

Whether a drain ALSO appends a convention-delta line to the changelog beside the master
(`../living-workflow/changelog.md`) is decided by the master's DRY-BY-REFERENCE scoping rule —
read it there. The changelog is a convention-delta for dependents and is owned entirely by the
master: its purpose, its co-location, its MASTER/harness scoping, its contract, and the
reconciliation walk all live there. This doc adds nothing to it. The operational shape of the
drain, for a groomer executing the loop, is stated once in grooming step 5 above.

## Entry file shape

```
# <short generalized title>

- Status: <BACKLOG | GROOMED | NEEDS-EVIDENCE:<what-would-decide-it> | DROPPED>
- Origin: <sanitized provenance — no session/project specifics>
- Target: <which doc + part this would tune, in generic terms>

## Candidate
<the generalized tuning>

## Justification (evidence)
<the abstracted friction/observation motivating it — no specifics>

## Notes / non-goals
<scope boundaries; why it is non-prescriptive>
```
