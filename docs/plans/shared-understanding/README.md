# shared-understanding — LLM bootstrap

The grooming thread carved from the operator's 2026-09-01 dump. Their goal
sentence, verbatim because it reads two ways: **"the goal crosses the whole
system but it's to shift the board as a whole for human reasoning."** This carve
leans the system-wide reading — grammars, plan machinery, presentation and the
board app as peer groups — and the operator separates intent from that reading
at grooming (see `WORK-SHARED-UNDERSTANDING`). Their mission line for the
branch: **promote a shared understanding between human and LLM.**

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

- **Agile, HITL.** No enforced order. The operator pivots to whatever they judge
  the worst gap when a session works this thread. Do not pick the next item for
  them.
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

## Origin

Carved 2026-09-01 from one operator dump (session scratchpad,
`dump-verbatim.md`, not committed) and gap-checked against it by independent
readers. `WORK-BOARD-EDGE-STYLES` and `WORK-BOARD-PLAN-VIEW` moved in from
`docs/plans/whiteboard-view/`; `WORK-BOARD-FILTER-MODEL` deliberately stayed
there.
