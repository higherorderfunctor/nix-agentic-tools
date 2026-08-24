---
name: sdoc
description: >-
  Use when authoring, editing, or reviewing StrictDoc .sdoc design nodes in this
  repository — plans under docs/plans/, settled architecture under **/.sdoc/, or
  the grammar itself. Covers the layout, the node types, the required validation
  loop, and the parser gotchas that fail closed.
---

Design nodes in this repo live in one StrictDoc graph rooted at the repository
root. Plans decay and are eventually collected; settled architecture outlives
them.

## Layout

| path                       | holds                                                                     |
| -------------------------- | ------------------------------------------------------------------------- |
| `strictdoc_config.py`      | project root config: the `@repo` grammar alias and the markdown exclusion |
| `docs/sdoc/grammar.sgra`   | the one grammar, shared by every document                                 |
| `docs/plans/<plan>/*.sdoc` | a named plan. One directory per plan, many files per plan. Decays.        |
| `**/.sdoc/*.sdoc`          | settled architecture about the package it sits beside                     |

Every document opens with the same two blocks. The alias is what lets a document
at any depth share one grammar — `IMPORT_FROM_FILE` otherwise accepts only a
bare filename resolved next to the document, which would need a grammar copy per
directory.

```
[DOCUMENT]
TITLE: <title>

[GRAMMAR]
IMPORT_FROM_FILE: @repo
```

## Node types

| tag         | prefix   | use for                             | notes                                       |
| ----------- | -------- | ----------------------------------- | ------------------------------------------- |
| `DECISION`  | `DEC-`   | a choice, open or closed            | immutable roots: no `DEPTH`, no `PARENT_FP` |
| `MECHANISM` | `MECH-`  | a thing that exists or will         | the workhorse                               |
| `SLICE`     | `SLICE-` | a vertical unit of deliverable work | `Crosses` the mechanisms it needs           |
| `INVARIANT` | `INV-`   | a rule that must hold               | "interface satisfied, rule violated"        |
| `SPIKE`     | `SPIKE-` | a probe that decides something      | carries `STATUS` and `RETIRES_ON`           |

Relation roles: `Governed_By` (→ a `DECISION`), `Crosses` (`SLICE` →
`MECHANISM`), `Guarantees` (→ an `INVARIANT`), `Proven_By` (→ a `SPIKE`),
`Assumes`, `Serialized_By`, `Superseded_By` (`DECISION` → `DECISION`), and
`File`.

## The three governance fields

- **`DEPTH`** — `sketch` / `needs-design` / `needs-spike` / `interface-settled`
  / `implemented` / `verified`. Declares intent. The `needs-*` values are the
  design worklist. `implemented` means code landed and is **unreviewed**;
  `verified` means an independent session checked the code against the node.
  **The gap between them is the review queue** — `DEPTH == implemented` is the
  query.
- **`AUTHORED_BY`** — `llm` / `human`. Who wrote the statement. Starts mostly
  `llm` by design; the point is that it grows.
- **`PARENT_FP`** — `<PARENT-UID>:<hash>` per parent whose contract this node
  depends on. Fingerprints point strictly **downward**: `DECISION` → `MECHANISM`
  → `SLICE`, so a collectable node never has an inbound fingerprint to strand.
- **`RETIRES_ON`** — required on `DECISION` and `SPIKE`. The forcing function. A
  deferred decision with no retirement condition is avoidance, not deferral.

Readiness is **not** a field. It is a query: a slice is implementable when every
mechanism in its closure is `interface-settled` or better, every decision in it
is `accepted`, and no edge is suspect. The count of `open` decisions in that
closure is the slice's degrees of freedom.

## Required loop after any edit

```bash
SD=$(command -v strictdoc)
"$SD" format .                                    # canonical form BEFORE hashing
"$SD" export . --formats=json --output-dir build  # parse == validate; exit 0 required
```

Validation is not a separate command — it runs at parse time, so any export
validates. Non-zero exit means the graph is broken. Do not proceed.

## Hard rules

1. **Never invent a UID.** Run `strictdoc manage auto-uid .` — the `PREFIX` on
   each grammar element supplies the right prefix.
2. **Never hand-write a node from memory.** `strictdoc manage new` scaffolds
   valid boilerplate in the right position. Field order and blank-line rules are
   what get subtly wrong.
3. **Never edit `PARENT_FP`.** Only a human accepts a contract change; the hash
   transition in a commit is the signature. An agent that clears its own
   fingerprints is a rubber stamp.
4. **Never edit an accepted `DECISION`'s `STATEMENT`.** Set its `STATUS` to
   `superseded`, add `Superseded_By`, and write a new decision.
5. **Always `format` before hashing.** `format` rewraps prose, so a fingerprint
   taken over unformatted text churns on its own.
6. **Never set `AUTHORED_BY: human`.** It records who wrote the statement, and
   only the operator turns that key — at pull-request review, not here.
7. **Commit as you go, unprompted.** One commit per unit of work, not one at the
   end and not only when asked. The branch is long-lived and gets restacked into
   pull requests later, so commit boundaries are what make that restack legible.
   Update the node you are working on in the same commit: raise its `DEPTH`, set
   a `SPIKE`'s `STATUS`, and record measured numbers in `NOTES`.

## Gotchas that fail closed

- **Field order is enforced.** Node fields must appear in grammar order. When
  extending the grammar, **append** — inserting mid-list means repositioning the
  field in every existing node.
- **One blank line between nodes**, and **no blank line between grammar
  elements**. Both are parse errors.
- **A `TAG:` starting with `SECTION` will not parse** — it collides with the
  built-in `[SECTION]`. Treat `SECTION*` as reserved.
- **`File` relations take `VALUE` only** — no `ROLE`, no `REVERSE_ROLE`. A
  `REVERSE_ROLE` under `TYPE: File` is a hard grammar syntax error.
- **`format` and `export` write a cache into `./output/` by default.** Always
  pass `--output-dir`, and never `git add -A` after running either from the repo
  root — the cache is gitignored now, but it will still bloat a staging area if
  the ignore is missed.
- **One error per run.** A hundred identically-broken documents report one
  error. Script the fix loop rather than iterating by hand.

## Gotchas that fail SILENTLY — these are the dangerous ones

- **`--filter-nodes` is ignored by the JSON exporter.** It works for HTML only.
  Never build a gate or a view that relies on it; filter in your own code.
- **Cycles among role-carrying relations are NOT detected.** StrictDoc's cycle
  check only sees role-less edges, and nearly every relation here carries a
  role. A cycle surfaces as a recursion-depth crash during render, not an error.
  Cycle detection has to live in our own checker.
- **Incremental export produces false greens.** A broken input can exit 1, then
  exit 0 on re-run against the same output directory. Any gate must use a clean
  output dir.
- **`manage new` pre-fills required choice fields with `TBD`**, which parses
  clean. Treat a `TBD` as unfilled.

## Backlog protocol — applies to planning AND implementation sessions

**Log incidental findings; do not narrate them.** Raise something in session
output only when it matters **soon** — it changes the decision in front of the
operator, or it blocks the work in hand. Everything else, the whole class of
"one more thing you should know", goes into the plan's backlog and stays
unspoken.

You may add backlog nodes **on your own initiative, without asking.** You
should.

- Each plan directory may hold a `99-backlog.sdoc`.
- An ungroomed item is an ordinary node at `DEPTH: sketch` — a `MECHANISM` to
  build, a `DECISION` to make, a `SPIKE` to run. **There is no `BACKLOG` node
  type**, deliberately: the existing types already say what kind of work it is.
- Grooming means moving the node into a numbered document in the same plan and
  raising its `DEPTH`. The UID never changes, so nothing citing it breaks.
- A plan's ungroomed set is the query `DEPTH == sketch` scoped to its directory.

The operator's judgment budget is the scarce resource. A logged finding is not
lost; mentioning it costs attention, logging it costs nothing.

## What does not exist yet

There is no suspect-link detection, no readiness query, and no derived view.
Until those land, **a human or an agent reading the diff is the only check that
a contract change was propagated** — the parser proves an edge resolves, never
that its two ends agree. Say so plainly rather than implying the graph is
verified.
