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

| path                       | holds                                                                      |
| -------------------------- | -------------------------------------------------------------------------- |
| `strictdoc_config.py`      | project root config: the `@repo` grammar alias and the markdown exclusion  |
| `docs/sdoc/grammar.sgra`   | the one grammar, shared by every document. **GENERATED — never hand-edit** |
| `docs/plans/<plan>/*.sdoc` | a named plan. One directory per plan, **one node per file**. Decays.       |
| `docs/spec/*.sdoc`         | the plan model itself — the nodes describing how plans work                |
| `**/.sdoc/*.sdoc`          | settled architecture about the package it sits beside                      |

**A file is named for the node it holds: the UID, lowercased, plus `.sdoc`.**
`MECH-FP-CHECK` lives in `mech-fp-check.sdoc`. The document's `TITLE` is the
node's own `TITLE`. There is no numbered-document convention any more — `01-`,
`02-`, `99-` prefixes ordered nodes within a file, and a file holds one node.

`grammar.sgra` is rendered from `packages/strictdoc-grammar/values.nix` by
`devenv tasks run generate:sgra`. A hand edit reddens
`strictdoc-grammar-model-equal`, which is inside `nix flake check`. To change
the grammar, change `values.nix` and regenerate.

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

`STATUS` is polymorphic and both spellings are required on their node type:
`DECISION` takes `open` / `accepted` / `rejected` / `superseded`, `SPIKE` takes
`unrun` / `run` / `blocked`.

Relation roles: `Governed_By` (→ a `DECISION`), `Crosses` (`SLICE` →
`MECHANISM`), `Guarantees` (→ an `INVARIANT`), `Proven_By` (→ a `SPIKE`),
`Assumes`, `Serialized_By`, `Superseded_By` (`DECISION` → `DECISION`),
`Backlogged_In` (→ a plan's backlog register), and `File`.

## The four governance fields

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

## Write with `sdoc`, not with the edit tool

`sdoc` is this repository's writer for the graph (SLICE-SDOC-CLI). **Its option
surface is DERIVED from the grammar** — one flag per field a node type declares,
one per relation role it may make, and every choice flag's word list read off
that field — so `sdoc new DECISION --help` and `sdoc new SPIKE --help` print two
different surfaces, and neither can be got wrong from memory.

```bash
sdoc new MECHANISM --help          # the flags MECHANISM actually declares
sdoc new MECHANISM --uid MECH-THING --title "..." --depth sketch \
     --statement @statement.md --path docs/plans/<plan>/
sdoc set MECH-THING --depth implemented --notes @notes.md
sdoc relate MECH-THING --role Governed_By --target DEC-SOMETHING
sdoc show MECH-THING               # the node, with relations resolved to titles
sdoc list --type SPIKE --depth sketch
sdoc check                         # every node, relation and File path
```

Every writing verb takes **`--dry-run`**, which prints the diff and writes
nothing. Every field flag takes **`@FILE`** to read the value from a file and
`-` to read it from stdin — which is how a multi-paragraph `STATEMENT` gets in
without a shell-quoting accident.

What the tool does that hand-editing does not: it applies the change in memory,
validates the node against the grammar, writes the file in **canonical form
through strictdoc's own writer**, and then reloads the whole graph to prove it
still parses — **restoring the original bytes if it does not.** So `format`
afterwards is not a step any more, and a command that cannot validate leaves no
changed file behind.

Two fields have **no flags at all** and that is the enforcement: `AUTHORED_BY`
and `PARENT_FP` are the operator's (MECH-RUNTIME-WRITE-GUARD). Naming one exits
non-zero saying who owns it. There is no override.

`sdoc` reaches strictdoc's own interpreter and needs a dev shell, like every
other strictdoc command here.

## Required loop when you edit a `.sdoc` by hand anyway

`sdoc` covers node and relation writes. For anything outside it — editing the
`[DOCUMENT]` header, or a bulk fix across many files — the old loop still
applies:

```bash
SD=$(command -v strictdoc)
"$SD" format .                                    # canonical form BEFORE hashing
"$SD" export . --formats=json --output-dir build  # parse == validate; exit 0 required
```

Validation is not a separate command — it runs at parse time, so any export
validates. Non-zero exit means the graph is broken. Do not proceed.

`format` takes no `--output-dir` and writes `./output/` unconditionally; only
`export` can be redirected. `format` also rewrites `.sdoc` only — a `.sgra` file
is read and never written, so it is not the grammar's formatter.

## Hard rules

1. **UIDs are hand-chosen and semantic.** `MECH-SDOC-LEAN-FORMATS`, not
   `MECH-7`. All 161 nodes are named this way — and since each is its own file,
   the UID is also the filename — by the operator's 2026-08-27 ruling: they read
   rendered views, and an index is a handle they cannot dereference. **Do not
   run `strictdoc manage auto-uid`** — it mints prefix-plus-counter, which is
   the form nobody here keeps.
2. **Never hand-write a node from memory — use `sdoc new`.** Field order and
   blank-line rules are what get subtly wrong, and the tool takes both from the
   grammar rather than from your recollection. It also refuses a UID whose
   prefix does not match the node type, which strictdoc itself does not check.
   `strictdoc manage new` works in this tree but do not use it: it mints a
   `MECH-1`-style UID that rule 1 forbids, and fills every required field with
   `TBD`, which parses clean.
3. **Never edit `PARENT_FP`.** Only a human accepts a contract change; the hash
   transition in a commit is the signature. An agent that clears its own
   fingerprints is a rubber stamp.
4. **Never edit an accepted `DECISION`'s `STATEMENT`.** Set its `STATUS` to
   `superseded`, add `Superseded_By`, and write a new decision.
5. **Always `format` before hashing** — unless `sdoc` did the write, which
   already emits the canonical form. It does not rewrap prose _today_ —
   `strictdoc_config.py` sets no `document_line_width`, so the round-trip is a
   no-op on paragraph text and only node structure is normalized. Run it anyway:
   MECH-TREEFMT-SDOC would set that width, and a fingerprint taken over
   unformatted text would then churn on its own.
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
  field in every existing node. Extend it in
  `packages/strictdoc-grammar/values.nix` and regenerate; the `.sgra` is output.
- **Relation order inside a node is NOT enforced**, unlike field order —
  measured 2026-08-27 by moving a role to the front of a `RELATIONS:` block and
  watching it parse clean. The role itself IS checked: an unregistered one fails
  with `Requirement relation type/role is not registered`. Keep relations in
  grammar order anyway, so `format` diffs stay quiet, but do not expect the
  parser to catch a stray one.
- **One blank line between nodes**, and **no blank line between grammar
  elements**. Both are parse errors.
- **A `TAG:` starting with `SECTION` will not parse** — it collides with the
  built-in `[SECTION]`. Treat `SECTION*` as reserved.
- **`File` relations carry `VALUE` only — by convention here, not by the
  parser.** Measured: a `ROLE:` under `TYPE: File` parses clean. Only adding a
  `REVERSE_ROLE:` is a hard grammar syntax error. Keep to `VALUE` alone so the
  corpus stays uniform, but do not expect the parser to enforce it.
- **`format` and `export` write a cache into `./output/` by default.** Pass
  `--output-dir` to `export`; `format` has no such flag and cannot be
  redirected. Never `git add -A` after running either from the repo root — the
  cache is gitignored now, but it will still bloat a staging area if the ignore
  is missed. Note the asserted literal is `Output/_cache` with a capital O, and
  `STRICTDOC_CACHE_DIR` is read BEFORE the config value and overrides it.
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

## Verifying — prove the test tested what you think

Running a command is not evidence until you know it exercised the thing you
meant. Two failures of this happened while building the current tooling:

- A search returned no `.sdoc` results and was reported as a confirmed defect.
  The cause was `PYTHONPATH` in the calling shell shadowing the binary under
  test — the working code was never run. See `MECH-SEMBLE-TEST-RECIPE`.
- A cycle was injected to test cycle detection, and the injection broke the
  file's syntax instead. The export failed for an unrelated reason and the grep
  matched the word "cycle" in prose.

So: **a negative result needs a positive control as much as a positive one
does.** Before reporting that something does not happen, show the same harness
detecting it when it should. Before reporting that a check passes, break the
thing it checks and watch it fail.

## Backlog protocol — applies to planning AND implementation sessions

**Log incidental findings; do not narrate them.** Raise something in session
output only when it matters **soon** — it changes the decision in front of the
operator, or it blocks the work in hand. Everything else, the whole class of
"one more thing you should know", goes into the plan's backlog and stays
unspoken.

You may add backlog nodes **on your own initiative, without asking.** You
should.

- **One node per file, and the file is named for the UID.** One requirement, one
  plan step, one milestone, one backlog item, one decision — one. The graph is
  pulled in along edges, so the unit a reader fetches has to be the unit the
  graph addresses. Write the new node to
  `docs/plans/<plan>/<uid-lowercased>.sdoc`. See `MECH-ONE-NODE-PER-FILE`.
- The corpus was carved to this shape on 2026-08-27; no `99-backlog.sdoc`
  survives. What it cost while it existed, since that is the argument for not
  rebuilding it: the corpus averaged 2.7 KB per node, and reading one node out
  of `99-backlog.sdoc` cost 279 KB, because that one file held 110 of them.
- **File it against the plan's backlog register.** A new item carries
  `Backlogged_In` to `MECH-BACKLOG-<PLAN>` — the linchpin node every ungroomed
  item in that plan points at. The register holds no list; the edges are the
  list. See `DEC-BACKLOG-IS-A-REGISTER-NODE`.
- **That edge does not use up the item's parents.** Give it `Governed_By`,
  `Crosses`, `Assumes` to whatever it actually relates to as well. Containment
  by edge composes; containment by file did not. A web is the point.
- An ungroomed item is an ordinary node at `DEPTH: sketch` — a `MECHANISM` to
  build, a `DECISION` to make, a `SPIKE` to run. **There is no `BACKLOG` node
  type**, deliberately: the existing types already say what kind of work it is.
- **Grooming no longer moves a file.** It raises the node's `DEPTH` where the
  node already sits, and drops the `Backlogged_In` edge. Moving between
  documents was how a node left the backlog when the backlog was a file.
- A plan's ungroomed set is the register's inbound `Backlogs`. The query
  `DEPTH == sketch` scoped to the directory answers the same question and is
  worth keeping as a **cross-check**: the two disagreeing means somebody filed
  without attaching, or groomed without detaching. Nothing enforces the pair yet
  — `MECH-SDOC-LAYOUT-CHECK`.

The operator's judgment budget is the scarce resource. A logged finding is not
lost; mentioning it costs attention, logging it costs nothing.

## What exists, and what still does not

Suspect-link detection, the readiness query and a derived view all shipped on
this branch: `dev/scripts/fp-check.py`, `docs/sdoc/status.py`'s
`closure_verdict()`, and `docs/sdoc/render.py`. The first is a required check.

`sdoc` shipped with milestone two (SLICE-SDOC-CLI): the grammar-derived writer,
`dev/scripts/sdoc_model.py` beneath it, and `dev/scripts/file-check.py` in
`nix flake check` alongside the cycle and fingerprint checks. It applies **no
instance semantics** — whether `DEPTH` may regress, when deleting is legitimate,
and who may sign are milestone five's, and `delete` exists in the tool precisely
because this skill is what does not teach it.

What is still true: **nothing has ever been signed.** All 31 fingerprint entries
are placeholders — 0 signed, 0 suspect — so no contract change has yet been
accepted by anyone. The parser proves an edge resolves, never that its two ends
agree. Say so plainly rather than implying the graph is verified.
