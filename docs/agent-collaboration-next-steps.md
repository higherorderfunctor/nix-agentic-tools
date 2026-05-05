# Agent Collaboration — Next Steps Punch List

> **What this is:** mini-plan / TODO captured at session-end so a
> future session (yours or a fresh one) can pick up without
> re-deriving context. Iterate down as items resolve.
>
> **Status:** v0.1 (genesis 2026-05-04). Open items below.

## Why this file exists

The protocol (`agent-collaboration-protocol.md`) and the
mechanism doc (`agent-collaboration-mechanism.md`) are written
but not yet usable as designed — they live in `docs/` as drafts
and need to be wired into an auto-load mechanism so the protocol
is active without manual file references in every prompt.

Several decisions about that wiring are deferred. This file
captures them so you don't have to re-explain to a new session.

## Open decisions

### 1. Where does the protocol live permanently?

The protocol is written ecosystem-neutral so it can be loaded
into any AI tool (Claude, Copilot, Kiro). Three plausible
homes:

- **In this repo** (`nix-agentic-tools`) — wired through this
  repo's existing `ai.instructions` fan-out. Loads in any
  project that consumes this repo's HM module or devenv
  module.
- **In your nixos-config / personal dotfiles** — wired
  user-globally so it loads in every project regardless of
  whether nix-agentic-tools is consumed.
- **In a separate dotfiles repo** — if you want the protocol
  decoupled from nix-agentic-tools entirely (e.g. for sharing
  with team members who don't use Nix at all).

Scope decisions matter: cross-project (HM scope) is more
universally applied, but per-project (devenv scope) lets you
test the protocol in one repo before committing to using it
everywhere.

**Recommended starting point:** devenv scope in this repo
first (smallest blast radius, easiest to iterate on). Promote
to HM scope once stable.

### 2. How to make the mechanism doc readable but NOT auto-loaded?

The protocol doc should be auto-loaded into every session.
The mechanism doc (research, citations) should NOT — it's
reference material rarely needed, and auto-loading it would eat
context for no good reason most of the time.

But the mechanism doc still needs to be discoverable and
loadable on demand (e.g. when revising the protocol, the agent
needs to read it for grounding).

Mechanisms to consider:

- Keep the mechanism doc as a plain on-disk file. Agent can
  `Read` it when explicitly asked.
- Wire it as a skill (invoked when agent decides it's
  relevant). Risks: skill-induced mode switch (see protocol
  anti-patterns); agent may not invoke it when it should.
- Reference it from the protocol doc with a path so any agent
  reading the protocol knows where to find it. This is the
  approach the protocol's self-onboarding header already
  takes.

**Recommended starting point:** plain on-disk file referenced
from the protocol's self-onboarding header. No special wiring.
Agent reads it when the human says "we need to revise the
protocol" or similar.

### 3. Repo conventions — defer

This repo has specific conventions for `ai.instructions` entries
(content shape, frontmatter requirements, fan-out path
contracts). Don't dig into those now — capture as TBD.

The future wiring session needs to:

1. Read the actual `ai.instructions` schema and existing
   entries.
2. Determine the right shape for a behavioral-protocol entry
   (vs. e.g. a coding-standards entry).
3. Implement the wiring.
4. Verify the protocol shows up at the right ecosystem paths
   (`.claude/rules/`, `.github/instructions/`,
   `.kiro/steering/`, `AGENTS.md`).

## Post-write tasks (if we resume soon)

- [ ] Run `treefmt` on all four files.
- [ ] Commit the four collaboration docs as a single commit.
- [ ] Test the protocol in a fresh session: open a new session,
      reference the protocol path, give a small task, observe
      whether the protocol's mode/trigger conventions actually
      get followed.
- [ ] Capture observations from the test session in the
      protocol's evolution log (or at the top of this file as
      "session N findings").

## Iteration discipline

The protocol is v0.1. Expect revisions. The protocol itself
(end-of-doc section "How to evolve this protocol") prescribes
the iteration discipline:

1. Document the observation.
2. Reference the relevant section.
3. Propose a revision with rationale.
4. Apply via the wiring (once wiring exists).
5. Update version + revision note at top of protocol doc.

Add an entry below for each observed iteration.

## Iteration log

- **2026-05-05** — Cross-session reconciliation captured at
  `docs/agent-collaboration-reconciliation.md`. Synthesis from a
  parallel claude.ai web session. Closes four previously-open
  items (self-reporting, stuck threshold, DECISION trigger,
  planning-session drift) by deciding NO or pointing at
  existing structural mitigation. Adds new protocol elements
  (dilution/channel terms, node types, /clear + plan.md, prompt
  patterns table, verifier v0.2 spec, diff-decisions verifier).
  Next session: produce v0.2 protocol docs incorporating the
  reconciliation. Wiring and migration explicitly out of scope.

## Sharing with team — later

Once the protocol is stable and you've used it a few times:

- File 1 (protocol) and File 2 (mechanism) are written for
  generic sharing. They have no Nix references, no
  nix-agentic-tools references, no personal observations.
- File 3 (this-repo wiring) and File 4 (next-steps) are NOT for
  sharing. Repo-specific.
- Team members on Kiro/Copilot without Nix would need their
  own install path — likely a manual copy of File 1 into their
  ecosystem's auto-load location (e.g.
  `.kiro/steering/agent-collaboration-protocol.md`).
- Worth a separate "team adoption" doc if/when this becomes a
  team thing. Out of scope until the protocol proves out for
  you personally.

## Versioning

This document is v0.1. Co-evolves with the others. Bump when
items resolve or new ones surface.
