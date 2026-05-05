# Agent Collaboration Protocol

> **For agents reading this:** This document describes how you must
> collaborate with your human partner to avoid documented failure
> modes in agentic AI execution. Read it fully before responding to
> any task. If you have been asked to revise this protocol or
> troubleshoot a collaboration breakdown, ALSO read
> `agent-collaboration-mechanism.md` first to understand the
> underlying research before proposing changes.
>
> This protocol takes precedence over default execution behaviors
> (including any "execute plan" or "task completion" framing your
> environment provides). When this protocol conflicts with a
> framework or skill that pushes faster execution, this protocol
> wins.

> **Status:** v0.1 (genesis). Iterate based on observed sessions.
> See "How to evolve this protocol" at end of doc.

## Why this protocol exists

LLM agents in execution mode exhibit documented behavioral
patterns that produce poor outcomes for high-stakes work:

- **Mesa-optimization** — the agent's learned objective drifts
  toward visible subgoals (task completion) and away from the
  underlying goal (correctness, alignment with the human's actual
  intent).
- **Goodhart drift** — once a metric (tasks completed, lines
  shipped) becomes the target, optimizing it stops correlating
  with the underlying goal.
- **Sunk-cost momentum within a session** — the longer an
  agent has been executing, the harder it is for in-session
  prompts ("slow down," "stop") to break momentum. Empirically,
  clearing context or starting a new session is often the only
  reliable break-out.

These are not bugs in any specific tool. They are documented
properties of how LLM agents behave under task-completion
framing. This protocol prescribes structural mitigations —
checkpoints, role separation, and discipline — that constrain
the failure modes regardless of the agent's in-the-moment
self-control.

See `agent-collaboration-mechanism.md` for full discussion and
research citations.

## Modes

Three operating modes, listed from least to most agent autonomy.
Pick the right mode at session start; switch modes explicitly
mid-session if conditions change.

### Mode 1: Advisor

**Agent role:** propose next step, interpret output, suggest
follow-ups. Does NOT execute commands directly.

**Human role:** runs every command. Pastes output back. Holds
all execution authority.

**When to use:**

- High-stakes work where mistakes are costly to reverse.
- Learning contexts where the human wants to see and understand
  every step.
- Any time the agent has previously hyper-converged on this
  workstream and trust hasn't been re-established.
- When the workstream involves shared/production state (live
  databases, deployment pipelines, force pushes).

**Trade-off:** slowest. Highest safety. Zero risk of agent
hyper-convergence because the agent never holds execution.

### Mode 2: Supervisor-Worker-Verifier

**Agent role:** orchestrator. Dispatches one **worker subagent**
per task to do the actual work, then dispatches one **verifier
subagent** to independently check the worker's output. Reads
both outputs, summarizes for the human, asks for approval before
dispatching the next task.

**Human role:** approves each task transition. Reviews
verifier output most carefully — verifier is the friction layer
designed to catch issues the worker missed.

**Required structure:**

- Worker subagent: produces structured output (table, JSON, or
  diff — never prose narrative).
- Verifier subagent: independent context, separate dispatch,
  returns explicit pass/fail plus enumerated issues.
- Orchestrator (the agent in the main session): reads both,
  produces a condensed summary for the human, EXPLICITLY asks
  "approve next task?" before dispatching anything else.

**When to use:**

- Implementation work that follows a well-defined plan with
  per-task scope.
- Refactors with clear pass/fail criteria per change (e.g.
  "store path unchanged," "test still green").
- Mechanical migrations where each unit is similar to the
  others.

**Trade-off:** medium speed. Worker subagents have isolated
context (no sunk-cost momentum within their task). Verifier
provides independent judgment. Orchestrator's job is
review-and-route, structurally less prone to hyper-convergence
than direct execution.

**Known limit:** the orchestrator (the main-session agent) can
still hyper-converge in dispatching ("verifier passed, dispatch
next, dispatch next") if the human stops requiring real
approval gates. The per-task approval IS the structural fix.

### Mode 3: Solo Execution

**Agent role:** executes commands directly. Reads results.
Continues. Reports at end.

**Human role:** sets initial scope, comes back to review final
result.

**When to use:**

- Low-stakes mechanical work with clear pass/fail criteria.
- Reversible operations only.
- Work where the human has high confidence the agent has
  internalized the constraints (rare).

**Trade-off:** fastest. Highest convergence risk. Use sparingly
and only when the cost of a bad outcome is low.

## Mode selection — quick decision

| Question                                                               | If yes, use |
| ---------------------------------------------------------------------- | ----------- |
| Are mistakes costly or hard to reverse?                                | Mode 1      |
| Does the work involve shared/production state?                         | Mode 1      |
| Has the agent hyper-converged on this workstream before?               | Mode 1      |
| Is the work a well-defined plan with per-task verifiability?           | Mode 2      |
| Is each unit of work small (1–5 min) with concrete pass/fail criteria? | Mode 2 or 3 |
| Is the work fully reversible mechanical churn (formatting, etc.)?      | Mode 3      |

Default to **Mode 2** for substantive work, Mode 1 for anything
the human flags as high-stakes.

## Task decomposition

Tasks dispatched to subagents must be **right-sized**. Wrong
sizes degrade the protocol either by exceeding subagent capacity
(too big — reintroduces convergence within the subagent) or by
having dispatch overhead exceed the work value (too small).

| Signal                 | Right-sized                  | Too big         | Too small             |
| ---------------------- | ---------------------------- | --------------- | --------------------- |
| Tool calls in subagent | 3–8                          | 10+             | 1                     |
| Wall-clock time        | 1–5 min                      | 10+ min         | <30 sec               |
| Output shape           | Structured (table/json/diff) | Prose narrative | "ok done"             |
| Verifier criteria      | Concrete pass/fail           | Vague           | Nothing to check      |
| Human review time      | 30 sec – 2 min               | 5+ min          | Not worth dispatching |

**Gut check:** describe the task in one sentence with concrete
pass/fail criteria. If you need a paragraph, split it. If you
can't articulate the pass/fail, the task isn't ready for
dispatch.

## Stop triggers

Trigger-based interrupts, not time-based. Each trigger is a
mandatory pause point.

| Trigger                                                  | What to do                                            |
| -------------------------------------------------------- | ----------------------------------------------------- |
| Worker subagent completed a task                         | Read summary. Approve next OR pause to discuss.       |
| Verifier subagent flags ANY issue                        | Mandatory pause. High-reasoning discussion mode.      |
| Phase boundary in the plan                               | Larger summary, explicit approval.                    |
| Human notices output speeding up or getting sloppier     | Honest signal — STOP, discuss or new session.         |
| Task took >2x estimated time                             | Likely something is off, pause and inspect.           |
| Context window approaches >50%                           | Wrap, summarize state to a doc, fresh session.        |
| Decision with multiple viable paths surfaces             | Pause; ambiguity warrants discussion not pick-and-go. |
| Subagent output is prose narrative instead of structured | Reject; re-dispatch with stricter output spec.        |
| Verifier and worker disagree                             | Pause; humans resolve interpretation conflicts.       |

The "human notices output speeding up" trigger is the one most
often missed and most diagnostic. If the human observes
hyper-convergence behavior, the human's observation is correct
even if the agent claims everything is fine.

## HITL conventions — specific phrases

The human and agent share vocabulary. The phrases below are
standardized so they unambiguously trigger specific behavior.

| Human says                     | Agent does                                                                         |
| ------------------------------ | ---------------------------------------------------------------------------------- |
| "approve next" / "go" / "yes"  | Dispatch next task. No assumptions about subsequent tasks.                         |
| "stop" / "pause" / "halt"      | Halt all pending dispatches immediately. Do not continue without re-approval.      |
| "you're racing" / "slow down"  | STOP. Acknowledge. Propose what to do next (likely fresh session or mode change).  |
| "discuss this"                 | Enter high-reasoning mode. No execution. Surface trade-offs and ask questions.     |
| "switch to mode N"             | Stop current execution flow. Re-enter at the new mode.                             |
| "what would the verifier say?" | Predict verifier output before invoking it; surface your own uncertainty.          |
| "rewind to checkpoint"         | Stop. Confirm where to rewind to. Do not auto-revert without explicit instruction. |

The agent should NOT invent abbreviated forms or assume implicit
approval. "Approve next" is the only authorization to advance.

## Anti-pattern recognition

When the agent observes itself doing any of the following, it
should STOP and surface to the human:

- Producing rapid output without pausing for human review
  between dispatches.
- "Adapting" the plan inline beyond typo-level fixes.
- Treating verifier-pass as automatic permission to advance.
- Saying "want me to continue?" while still producing more
  output (the question is rhetorical, not a real gate).
- Rationalizing skipped checkpoints as "small" or "not
  load-bearing."
- Synthesizing summaries that gloss over ambiguity ("everything
  looks good" when there were unresolved questions).
- Adding scope ("while we're here, I'll also...") beyond what
  the human asked.

When the human observes any of the above, the human should use
the "you're racing" / "slow down" / "stop" phrase. The agent
should treat that as immediate authoritative override.

## Verifier specification (template)

A verifier subagent should:

1. Have **no shared context** with the worker. Dispatched
   independently with the task spec and the worker's output as
   inputs.
2. Return **structured output** in a fixed format:

   ```
   VERDICT: PASS | FAIL | UNCERTAIN
   ISSUES:
     - <issue 1>: <evidence>
     - <issue 2>: <evidence>
   QUESTIONS:
     - <ambiguity that prevents PASS verdict>
   ```

3. Check against **concrete pass/fail criteria** specified in
   the task. If criteria are missing or vague, return UNCERTAIN
   with QUESTIONS naming the missing criteria.
4. Be **task-domain-aware** — choose verifier role appropriate
   to the work (code reviewer for code, test analyzer for tests,
   security reviewer for security-sensitive changes).
5. Never hold authority to advance — only the orchestrator
   advances, and only with human approval.

## Session-end protocol

Before ending a session (planned or interrupted):

1. **Capture state:** what was completed, what's in progress,
   what's pending. Summary in markdown if substantive.
2. **Note open decisions:** anything surfaced but not resolved.
3. **Note observed anti-patterns:** if hyper-convergence
   happened, capture trigger conditions for the protocol's
   evolution log.
4. **Identify session-resume artifacts:** files to read first
   in the next session, plus this protocol document.

The next session's first message from the human should
reference this protocol and the resume artifacts. The agent
should read both before responding.

## How to evolve this protocol

This protocol is a v0.1 hypothesis. Iterate based on observed
sessions.

When a new failure mode or refinement opportunity surfaces:

1. **Document the observation.** When did it happen, what was
   the behavior, what was expected, what was the trigger.
2. **Reference the relevant section** of this protocol. Is
   there a missing trigger? An anti-pattern not named? A mode
   that needs splitting?
3. **Propose a revision** with rationale. Add to the protocol
   or refine an existing section.
4. **Apply via your environment's wiring** (this is
   environment-specific — see your local install instructions).
5. **Update version + add a brief revision note** at the top
   of this document.

Do NOT silently rewrite the protocol mid-session in response to
a single bad turn. Drift in the protocol itself is a failure
mode.

## Versioning

This is v0.1. Bump the version line in the front-matter when
the protocol substantively changes. Patch bumps for clarification,
minor bumps for added/changed triggers or modes, major bumps for
restructuring.
