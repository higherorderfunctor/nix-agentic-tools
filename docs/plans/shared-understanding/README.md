# shared-understanding — LLM bootstrap

**This is not a plan to implement.** It is the operator's consciousness dump of
nits, missed expectations and fuzzy wants, carved on 2026-09-01 while those
expectations are still fuzzy — on purpose. A session on this thread is guided
elicitation: the operator picks a topic, and the session helps them pull out
what they actually want, name what they did not consider, and sharpen what is
fuzzy. There is no dependency order to work through, because nothing here is
ready to build.

Their goal sentence, verbatim because it reads two ways: **"the goal crosses the
whole system but it's to shift the board as a whole for human reasoning."** This
carve leans the system-wide reading — grammars, plan machinery, presentation and
the board app as peer groups — and the operator separates intent from that
reading at grooming (see `WORK-SHARED-UNDERSTANDING`). Their mission line for
the branch: **promote a shared understanding between human and LLM.**

## Load context

1. Invoke the `sdoc` skill; read `docs/sdoc/README.md` if you have not.
2. Read the root node and walk down:

   ```bash
   scribe show WORK-SHARED-UNDERSTANDING
   scribe list --type WORK   # or open the board's Plan tab
   ```

   The tree: root → five concept groups (`WORK-GRAMMAR-ARCHITECTURE`,
   `WORK-PLAN-LAYER`, `WORK-BOARD-SHIFT`, `WORK-SEMANTICS-AND-WORDS`,
   `WORK-CANON-STRUCTURE`) plus `WORK-PRESENTATION-GRAMMAR` directly under the
   root. A child hangs under its group by an `Assumes` edge — that edge is TREE
   STRUCTURE for the board's Plan tab, chosen by the carving agent, not an
   operator ruling. `REQ-BOARD-GRAMMAR-DRIVEN` is the one requirement the
   operator offered; everything else is WORK at `sketch`.

3. The board app renders this plan: `devenv up -d board`, then the Plan tab
   (tree, right-pane card) — http://127.0.0.1:8765/?view=plan

## Working protocol (the operator's rules)

- **The operator picks the topic.** Do not pick for them, and do not rank, order
  or schedule the items — a dependency analysis of this thread answers a
  question nobody has asked yet.
- **Help them extract, one step at a time.** Ask one question per turn, in plain
  words. Offer two or three concrete readings to react to rather than an open
  question. Say what they may not have considered. Drill deeper only on the
  topic they picked.
- **Write what surfaces back into the node in the same session.** The STATEMENT
  gets sharper; NOTES keeps their words verbatim.
- **Work items only, until groomed.** Nothing here converts to spec or
  presentation nodes without the operator in the loop.
- **Ambiguity is preserved, not resolved.** Where the dump was ambiguous, the
  item's NOTES carries the operator's verbatim (spelling cleaned) so they can
  separate intent from the carver's reading. Keep doing that.
- **Old plans are not superseded by this thread's existence.**
  `WORK-OLD-PLANS-RECONCILE` is the explicit grooming session for that.
- Standing sdoc rules apply: never `fp-accept`, never `AUTHORED_BY`, supersede —
  never edit — an accepted decision, log findings to
  `MECH-BACKLOG-SHARED-UNDERSTANDING` instead of narrating them.
- **Scope is the board viewer and StrictDoc in general, not only the carve.**
  The operator adds items on the fly. File each as a WORK node at `sketch`,
  under the concept group it fits or directly under the root.
- **The plan tracks what changed.** When a session changes something a node
  describes, update that node in the same commit. An outcome that is spec-worthy
  goes where settled things live — `docs/spec/` for the plan model, `**/.sdoc/`
  beside the package it describes — not only into a WORK node's NOTES.

## Root context

Root context is for the operator's conversation rounds. Protect it:

- **Delegate reading and mechanical edits.** A background agent or a small
  workflow opens the files, makes the change, commits it, and returns the
  conclusion — never the file dump. Reasoning needed to converse cannot be
  delegated; everything else can.
- **The bootstrap reads are the exception.** Memory block, skill, this README
  and the root node are shared ground and belong in root context.
- **Agents commit their own files by explicit path**, never `git add -A`, and
  the session sequences commits so two agents never race on the index.
- **Replies are terse.** The answer, what moved, then stop.

## Session prompt

Copy-paste to start a session from the primary checkout. At the end of a
session, ask for this prompt again — it lives here so it survives the session.

```
Grooming session on the shared-understanding plan — HITL, I drive.

Branch feat/strictdoc-trial, worktree:
  /home/caubut/Documents/projects/nix-agentic-tools-worktrees/strictdoc-trial
Edit there by absolute path only; never author in this checkout.

Bootstrap, in order:
1. Read the project_strictdoc_trial memory (latest session block first).
2. Invoke the sdoc skill (authoritative copy: <worktree>/dev/skills/sdoc/SKILL.md).
3. Read <worktree>/docs/plans/shared-understanding/README.md — the plan's own
   bootstrap — then `scribe show WORK-SHARED-UNDERSTANDING`.

The board app: `devenv up -d scribe board` from a shell in the worktree if not
already up; http://127.0.0.1:8765/?view=plan renders this plan.

This is not a plan to implement. It is my consciousness dump of nits, missed
expectations and fuzzy wants. Your job is to help me extract what I want, name what I did
not consider, and sharpen what is fuzzy — on the topic I pick. Never pick for
me, never rank or order the items. One question per turn, plain words, two or
three concrete readings to react to. I may add items outside the carve but in
scope (the board viewer, strictdoc in general); file them as WORK.

Work items only; nothing converts to spec/presentation without me. Ambiguities
stay verbatim in NOTES. Decisions come to me as plain-language cards, one per
turn. Never fp-accept, never AUTHORED_BY. Log incidental findings to
MECH-BACKLOG-SHARED-UNDERSTANDING, don't narrate them. Write what surfaces back
into the node the same session; spec-worthy outcomes go to sdoc where they
belong.

Protect your root context: delegate file reading and mechanical edits to
background agents or small workflows and take back only the conclusion. Terse
responses; explain designs, don't change them unasked. Commit as you go on the
branch.
```

## Origin

Carved 2026-09-01 from one operator dump (session scratchpad,
`dump-verbatim.md`, not committed) and gap-checked against it by independent
readers. `WORK-BOARD-EDGE-STYLES` and `WORK-BOARD-PLAN-VIEW` moved in from
`docs/plans/whiteboard-view/`; `WORK-BOARD-FILTER-MODEL` deliberately stayed
there.
