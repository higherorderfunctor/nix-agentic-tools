# Agent Collaboration — Cross-Session Reconciliation

> **Status:** session capture, 2026-05-05. Records the synthesis
> from reconciling this session's v0.1 protocol with a parallel
> session's findings (handoff document from claude.ai web,
> retired). Not a protocol document itself — input for the v0.2
> revision session. Becomes archive after v0.2 lands.
>
> **Audience:** the agent producing v0.2 of the protocol. Read
> alongside the four existing `docs/agent-collaboration-*.md`
> files.

## How to use this document

The next session reads this PLUS the four existing
`docs/agent-collaboration-*.md` files. This doc tells you WHAT
changes in v0.2; the existing docs are the source material.
Produce v0.2 by applying the deltas in this doc to the existing
docs.

Do NOT decide steering file placement or wiring
(`ai.instructions`, ecosystem paths). Do NOT engage with the
mcp-servers migration. Both are explicitly out of scope.

## What changed in the synthesis

The protocol's scope expands from "execution-mode
hyper-convergence" to "extended-session agent behavior failure
modes." Broader scope covers the same mechanism
(channel/dilution) producing multiple symptoms — execution
convergence, peer-review deference, premature structuring
during brainstorm. Decided in this session as load-bearing.

The mechanism framing tightened: **dilution** and **channel**
(terms from the parallel session) replace mesa-optimization as
the within-session mechanism. Mesa-optimization is preserved as
a training-time concept, distinct from within-session behavior.

The autonomy-axis modes (Mode 1/2/3) collapse to a per-node
modifier; the primary axis becomes **node types** (EXECUTE,
DECISION, RESEARCH, TRIAL, CHECKPOINT) from the parallel
session. Advisor mode (was Mode 1) becomes a per-node modifier
for high-stakes work.

Phase transitions get a concrete mechanic: **/clear** after
writing to **plan.md**. Hard reset, not soft compaction.

State and behavior get an anchor split: plan.md holds state;
CLAUDE.md holds behavior. Both serve as context anchors at
phase transitions.

The verifier specification becomes v0.2 with explicit context
boundaries (criteria + worker output IN; production history,
plan, orchestrator reasoning OUT) and explicit failure modes
(verifier converging on PASS, nitpicking off-spec criteria,
wrong role).

A new structural mitigation for silent decision-making:
**diff-decisions verifier**. Dispatched after a worker task
with ONLY the task spec and final diff. Job is decision
extraction, not correctness. Anything in the verifier's
extracted list not in the task spec's pre-decided forks is a
silent decision; surface to human before advancing.

A new protocol element for human-side discipline: **prompt
patterns**. Reference table of framings that unlock specific
agent behaviors. NOT a script — consulted when the human
notices a behavior they're not getting.

Two more elements from the parallel session: **brainstorm
mode** (distinct from plan/execute; agent asks questions,
produces no structure) and **probe-vs-verification TDD**
distinction.

## Closed by decision (previously open, now resolved)

The act of listing items as "open" creates pressure to solve
them, which becomes a channel. These items are now decided —
do NOT reopen them in v0.2.

- **Self-reporting under dilution.** Closed: NO. Known
  unreliable per both sessions and the human's empirical
  experience. Protocol does not rely on self-reporting
  callouts. Use structural mitigations (verifier,
  diff-decisions verifier, /clear) instead. Hook-based
  enforcement is tooling, not protocol — defer to a separate
  session if pursued.
- **Stuck threshold (N attempts before asking).** Closed: drop
  entirely. Replace with "agent halts and asks when uncertain"
  — judgment, not counting. A counter is the wrong abstraction.
- **DECISION trigger precision ("multiple valid approaches").**
  Closed: don't rely on agent judgment to recognize forks.
  Pre-decide known forks in the task spec. Encountered forks
  not in spec → HALT, not judgment-call.
- **Orchestrator drift in long planning sessions.** Closed by
  the same /clear discipline applied elsewhere. Planning is a
  phase; phase boundaries get /clear. No special case needed.

## New protocol elements (carry forward into v0.2)

**From the parallel session (handoff agent):**

- Dilution / channel terminology as primary mechanism for
  within-session convergence.
- Node types: EXECUTE, DECISION, RESEARCH, TRIAL, CHECKPOINT.
- Phase transition mechanic: /clear + plan.md handoff.
- Plan.md (state) vs CLAUDE.md (behavior) anchor split.
- Brainstorm mode distinct from plan/execute.
- Probe-vs-verification TDD distinction.
- Confidence-level discipline per asserted decision.

**From this session (kept from v0.1):**

- Anti-pattern recognition list.
- Per-task autonomy modifier (Advisor) applied to any node
  type for high-stakes work.
- HITL conventions table with specific phrases.

**From the synthesis (this exchange):**

- Verifier v0.2 specification: explicit context-window
  boundaries (criteria + worker output IN; production history,
  plan, orchestrator reasoning OUT), explicit failure modes
  (PASS-bias, off-spec nitpicking, wrong role), dispatch as a
  CHECKPOINT node not a separate concept.
- Diff-decisions verifier: post-task, diff-only context, job
  is decision extraction. Compares enumerated decisions
  against task spec's pre-decided forks; surfaces silent
  decisions before advancing.
- Peer-review framing as HITL convention: "Take positions.
  Push back where you have better reasoning. I'll arbitrate."
- Prompt patterns table — reference, not script. Examples for
  peer review, brainstorming, high-reasoning discussion, hard
  reset.

## Decisions made (bound v0.2 work)

- **Scope: broad.** Protocol governs extended-session agent
  collaboration generally. The underlying mechanism
  (channel/dilution) produces multiple symptoms; protocol
  addresses the mechanism.
- **Human as risk vector recognized.** Symmetric protocol — the
  human is also subject to forgetting load-bearing prompt
  framings. Prompt patterns table responds to this without
  becoming a script.
- **Peer-review framing kept in.** Not scope creep — it
  addresses a related symptom of the same mechanism.
  Empirically validated by use in this session.

## Genuinely open (empirical, not analytical)

Only two items. Both require real-session observation to
refine, not more design discussion. v0.2 should preserve
them as-is and note they tune empirically — they are NOT
blocking.

1. **Anti-pattern trigger calibration.** "Human notices output
   speeding up / agent racing" is the most diagnostic trigger.
   Tunes from real observation, not pre-design.

2. **Diff-decisions verifier evaluation.** Whether the verifier
   reliably extracts decisions vs. paraphrases the diff is
   empirical. Specify the verifier as designed; flag for
   first-real-session evaluation.

## Explicitly out of scope for v0.2 revision

- `ai.instructions` wiring (placement, ecosystem paths,
  fan-out mechanics). Separate session.
- mcp-servers migration. Protocol governs HOW migration
  happens; v0.2 production does NOT engage with the migration
  itself.
- Hook-based enforcement experiments. Not protocol content;
  potential future tooling.

If any of these surface as "we should also handle this," halt
and surface to the human. Deferred to subsequent sessions, not
addressed in v0.2.

## Output of the v0.2 session

The next session should produce:

- Revised `docs/agent-collaboration-protocol.md` (v0.2)
  reflecting the new node-type axis, prompt patterns table,
  verifier v0.2 spec, diff-decisions verifier, and closed-vs-open
  discipline.
- Revised `docs/agent-collaboration-mechanism.md` (v0.2)
  replacing mesa-optimization as the within-session mechanism
  with dilution/channel; preserving mesa-opt as a distinct
  training-time concept.
- Revised `docs/agent-collaboration-this-repo.md` if anything
  about its content changed (likely minimal — wiring intent
  unchanged).
- Revised `docs/agent-collaboration-next-steps.md` updated for
  what happens AFTER v0.2 lands.
- A list (in protocol or in next-steps) of what steering files
  should result. Names and contents, not placement.

## Source documents

- Original v0.1 docs: `docs/agent-collaboration-{protocol,mechanism,this-repo,next-steps}.md`.
- Reconciliation source (parallel session): handoff document
  from claude.ai web session, now retired. Notable quotes
  preserved within this document; original not committed to
  this repo.

## Versioning

This document is v1 (single capture, not iterated). Becomes
archive after v0.2 protocol lands.
