# Agent Collaboration — This Repo's Wiring (NOT shareable)

> **Audience:** future you working in nix-agentic-tools. Not for
> external sharing — references this repo's specific
> conventions. The shareable docs are
> `agent-collaboration-protocol.md` and
> `agent-collaboration-mechanism.md`.
>
> **Status:** v0.1 (genesis). Captures intent, NOT yet executed.
> The protocol is currently in `docs/` as a draft; permanent
> placement and wiring through this repo's fan-out pipeline are
> deferred to a follow-up session. See
> `agent-collaboration-next-steps.md` for the punch list.

## What this doc covers

- Where the protocol files live now (draft state).
- The intended wiring through this repo's existing AI-config
  fan-out (`ai.instructions` etc.).
- TODOs for cleanup once the wiring is settled.

## Current state (draft)

All four collaboration documents are currently in `docs/` as
markdown files for ease of iteration before commit to the
fan-out pipeline:

- `docs/agent-collaboration-protocol.md` — the operational
  protocol.
- `docs/agent-collaboration-mechanism.md` — research and
  citations.
- `docs/agent-collaboration-this-repo.md` — this file.
- `docs/agent-collaboration-next-steps.md` — punch list of
  follow-ups.

These are not yet wired into Claude/Copilot/Kiro auto-load
paths. They have to be loaded manually by referencing the file
paths in a prompt.

## Intended wiring (deferred)

This repo's AI-config fan-out exposes unified options
(`ai.instructions`, `ai.skills`, etc.) that emit per-ecosystem
artifacts. The collaboration protocol should be wired through
that mechanism so it auto-loads in every session.

**Working mental model — verify against actual repo conventions
before executing:**

- The protocol document (`agent-collaboration-protocol.md`)
  belongs as an `ai.instructions` entry — it's an
  always-loaded behavioral instruction, not a skill or agent.
- The mechanism document (`agent-collaboration-mechanism.md`)
  is reference material that should NOT be auto-loaded (it
  would eat context every session for content rarely needed).
  It needs to be on disk and accessible (so the agent can read
  it on demand when revising the protocol), but not in the
  always-loaded set.
- The this-repo doc and next-steps doc stay as plain
  `docs/`-style notes — neither is for the fan-out.

How to actually wire each — including whether to put the
protocol at HM scope (cross-project) or devenv scope
(this-repo-only), and what mechanism is right for File 2's
"available but not auto-loaded" requirement — is **deferred**
to a future session that focuses on the wiring itself.

See `agent-collaboration-next-steps.md` for the open questions
and decisions.

## Sharing-vs-private split

When the protocol is wired and the docs/ versions retired:

- `agent-collaboration-protocol.md` — shareable. Rewriteable as
  a standalone artifact for team members on different stacks
  (Kiro, Copilot, no Nix).
- `agent-collaboration-mechanism.md` — shareable as a deeper
  reference, but optional reading.
- `agent-collaboration-this-repo.md` — NOT shareable.
  References this repo's specifics.
- `agent-collaboration-next-steps.md` — NOT shareable.
  Internal punch list.

If sharing externally, also strip any references to this repo's
fan-out mechanics from the shareable two — they're already
written without those references, but verify before sharing.

## Cleanup checklist (after wiring is figured out)

- [ ] Decide permanent home for protocol + mechanism docs
      (this repo? nixos-config? separate dotfiles repo?).
- [ ] Wire protocol into `ai.instructions` (or whatever the
      right mechanism is) at the chosen scope.
- [ ] Wire mechanism doc to be on-disk-accessible without
      auto-load (mechanism TBD).
- [ ] Update protocol's self-onboarding header to point at the
      new file paths if they change.
- [ ] Delete or archive the docs/ draft copies.
- [ ] Update this repo's relevant memory entries / fragments
      to reference the new paths.

## Versioning

This document is v0.1. Bump when wiring decisions materialize
or the cleanup checklist changes substantively.
