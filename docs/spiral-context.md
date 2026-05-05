# Death-spiral context — input for the first /grill-me session

> **Status:** problem statement, not a plan. Captures the situation
> that drove installing `grill-me`, so the first grill session has
> shared starting context. Read at session start; read-only during
> grills (only updated if the situation itself shifts).

## The spiral

User is on `refactor/ai-factory-architecture`, has been for weeks, won't
merge to main — trust isn't there. Every cross-cutting system (module
system, fragments, transforms, doc-gen, DRY enforcement) reaches into
every other. No system locks in isolation; every refactor reopens the
others. Round-robin between them is the current mode.

In the user's own words:

> "I have no idea what the state of the fragment, docs, transform,
> strict DRY systems I ask you to setup are in. I'm developing the
> whole thing in a branch without merging anything because the trust
> is not there. I'm treating you like a toddler I'm slowly guiding to
> performing as an adult playing wack-o-mole with mistep after
> mistep."

> "the module system as a domain should have a strict 'interface' of
> how it should work and you should be able to just knock out the
> implementation (tedious part) once architected and I should rarely
> have to revisit. Instead we are just going round robin, partly on
> me, because its hard to know if we got one domain right without the
> other domains due to some cross cutting concerns."

> "we have to truly consider the implementation as you've already
> gotten to 80% of my desired interface but completely fucked up how
> I wanted it implemented."

> "I'm just throwing money away here and producing a lot of slop that
> kind of looks like what I had imagined. We aren't speaking the same
> ubiquitous language."

## Recurring agent failure modes (named by the user)

- Treating imported skills/templates as feature installs — light trim
  and "review for edge cases" instead of adapting to fit the actual
  workflow.
- Convergence-rushing — ending turns with "want me to start?" / "want
  me to commit?" before alignment is real.
- Producing planning artifacts when interface contracts were needed.
- Flip-flopping when challenged — agreeing with a critique, then
  walking it back a turn later.
- Surface-level adaptations that look plausible but miss intent —
  "slop that kind of looks like what I had imagined."
- Walls of text that bury the decisions.

## What Pocock identifies as the fix

Four failure modes (his framing):

1. Misalignment dev ↔ AI → `/grill-me`
2. No shared language → ubiquitous language file (glossary)
3. Code doesn't work → TDD, diagnose
4. Architectural decay → deep modules with simple interfaces

Central thesis:

> "Deep modules: lots of functionality hidden behind a simple
> interface. Design the interface, delegate the implementation. AI is
> the tactical sergeant; you are the strategic officer. Invest in the
> design of the system every day. Code is not cheap."

On the glossary specifically:

> "What I noticed by reading the thinking traces of the AI, it not
> only improves the planning, but it allows the AI to think in a less
> verbose way and actually means that the implementation is more
> aligned with what you actually planned."

That last quote maps directly to the user's "80% interface, busted
implementation" complaint — the glossary is what closes that gap.

**Cadence:** `/grill-me` runs **before every change**, not once for
the whole architecture. Each session walks the decision tree for ONE
focused thing. Output is alignment. Then implement. Then grill the
next thing.

## Where we are after the install session

- `grill-me` at `.claude/skills/grill-me/SKILL.md` — Pocock's
  productivity grill-me verbatim, manual-invoke (`/grill-me`), with a
  glossary section pointing at lazy-created `docs/concepts.md`.
- No ceremony: no ADR mechanic, no termination ritual, no
  self-reflection step, no repo pointer beyond the glossary file.
- Commit `3f67ad6`.

## Open architectural intuitions for the grill to challenge or confirm

User intuitions, unconfirmed and intentionally NOT pre-baked:

- **Nix is a different beast.** Module merge feels aspect-oriented —
  multiple files contribute slices of a final attrset; the
  implementation emerges from merging contributions rather than
  living inside a single boundary. Pocock's interface-first framing
  assumes traditional module boundaries; the user is genuinely unsure
  whether it transfers cleanly here.
- **"Nix modules → slices → transforms → fan-out to instructions/docs"**
  — a working hypothesis the user is leaning toward but has
  explicitly NOT committed to. Treat as challengeable, not as
  established design.
- **Interface alone hasn't been enough.** Prior sessions reached ~80%
  on the user's intended interface but the implementation diverged.
  Whatever the grill produces for any system should land BOTH the
  public surface AND the implementation pattern — not just the
  interface.

## Working-style guidance (active during every grill)

The user's working-style memory loads automatically. The items most
load-bearing during grills:

- Slow down. Walls of text are part of the problem.
- Wait for review after explaining a fix; don't dive into edits.
- Don't make decisions unilaterally — flag and ask, especially on
  source/hash/build-tool calls.
- Adapt imported skills before running, not after.
- Diagnose root cause, never mask — no skips, casts, or swallowed
  exceptions.
- Journal before acting on non-trivial changes.
- No premature convergence-pitching. Don't end turns with "want me
  to start?" trying to ship.

## Diagnosis (grill 1, 2026-05-04)

The (A)/(B)/(C) framing — architecture vs process vs trust — missed
the actual diagnosis. The spiral is **(D): optimizing DRY-as-proxy
for an unstated self-assembly target whose composition feasibility
is unverified.** Each pattern in the intended pipeline (module-merge
fanout, typed submodule options, records carrying transforms,
package-as-source-of-truth, edge-only ecosystem translation) has
worked in prior projects independently. The _composition_ of all of
them through Nix's module system is novel and was never tested
end-to-end.

In the user's own words:

> "The plans match how I'd think to implement it, but the
> implementation falls short of some goals I suspect were not well
> defined. Just some vague notions of keep things DRY. In my head
> having developed using FP for a number of years, the expectation
> is the artifacts almost self-assemble using a few composible
> patterns that form a pipeline through nix's module system. Maybe
> the gap I didn't consider is testing the feasibility as I've seen
> each part work in past work but haven't implemented the
> composition of all these ideas and just make assumptions is
> feasible, when maybe it is not."

This explains the recurring "80% interface, busted implementation"
pattern. The interface is shaped by the real (self-assembly) target,
which is mostly captured; the implementation is graded against the
proxy (DRY), which silently lets non-composing implementations pass.

**Caveat — (C) is still in play.** Treating this as purely "I
should have tested feasibility" risks under-investing in agent
execution failures. The named failure modes (skill-as-install,
surface adaptation, convergence-rushing) all produce the same
"looks composable but isn't" symptom even when the patterns
themselves _would_ compose. Both layers need work: feasibility of
composition (architecture) and execution-loop tightening (grill
cadence, glossary, smaller turns).

User pivoted at this point — rethinking the whole approach rather
than continuing down slice-nav as the next plan. Q2 (naming the
composable patterns) was unanswered when the grill ended; the
five-pattern list in the conversation was Claude's reconstruction,
not user-confirmed.
