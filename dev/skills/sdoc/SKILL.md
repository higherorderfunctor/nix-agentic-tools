---
name: sdoc
description: >-
  Use when authoring, editing, or reviewing StrictDoc .sdoc design nodes in this
  repository — plans under docs/plans/, settled architecture under **/.sdoc/, or
  the grammar itself. Covers the layout, the node types, the required validation
  loop, and the parser gotchas that fail closed.
---

<!-- cspell:ignore unrelate -->

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
node's own `TITLE`. The numbered-document convention (`01-`, `99-`) is gone with
the multi-node file it ordered.

`grammar.sgra` is rendered from `packages/strictdoc-grammar/values.nix` by
`devenv tasks run generate:sgra`. A hand edit reddens
`strictdoc-grammar-model-equal`, which is inside `nix flake check`. To change
the grammar, change `values.nix` and regenerate.

Every document opens with the same two blocks. The alias is what lets a document
at any depth share one grammar: `IMPORT_FROM_FILE` otherwise accepts only a bare
filename resolved next to the document.

```
[DOCUMENT]
TITLE: <title>

[GRAMMAR]
IMPORT_FROM_FILE: @repo
```

## Glossary — ruled terms, use them and correct drift on sight

| term       | means                                                                          | ruling                                   |
| ---------- | ------------------------------------------------------------------------------ | ---------------------------------------- |
| beads      | the LLM's working graph: private, one per user per repo, NOT part of the canon | `DEC-CANON-NAMES-THE-COMMITTED-CONTENTS` |
| canon      | the committed, human-reviewed `.sdoc` contents; never "graph"                  | `DEC-CANON-NAMES-THE-COMMITTED-CONTENTS` |
| checkpoint | a joint that fires on a workflow moment (commit, push, check)                  | `DEC-JOINT-NOT-SURFACE`                  |
| joint      | join point: a place logic COULD attach; never "surface"                        | `DEC-JOINT-NOT-SURFACE`                  |
| scribe     | the writer of the canon, CLI and library alike; the command is `scribe`        | `DEC-SCRIBE-NAMES-THE-WRITER`            |
| sdoc       | the file format and its grammar, nothing else                                  | `DEC-SCRIBE-NAMES-THE-WRITER`            |
| strictdoc  | the upstream package                                                           | `DEC-SCRIBE-NAMES-THE-WRITER`            |

## Node types

Ruled by `DEC-NODE-FAMILIES` (docs/spec): four families, and only the first is a
grid.

| tag           | prefix  | family                        | use for                                                                      |
| ------------- | ------- | ----------------------------- | ---------------------------------------------------------------------------- |
| `REQUIREMENT` | `REQ-`  | definition, normative x all   | what must always hold; can be violated                                       |
| `DECISION`    | `DEC-`  | definition, normative x one   | a choice, open or closed; in force once accepted; no `DEPTH`, no `PARENT_FP` |
| `MECHANISM`   | `MECH-` | definition, descriptive x all | how the system always behaves; can only be wrong                             |
| `EVIDENCE`    | `EV-`   | definition, descriptive x one | one observation: a probe's finding, a measurement, a log, an external source |
| `USE_CASE`    | `UC-`   | coverage                      | a path the specification must enable; covered or uncovered                   |
| `NARRATIVE`   | `NAR-`  | representation                | a maintained projection for a reader; its `Cites` edges go dirty             |
| `WORK`        | `WORK-` | work                          | something to do; `Crosses` its lane, `Produces` evidence, dies with its plan |
| `COMMENTARY`  | `CMT-`  | commentary (family OPEN)      | a remark ABOUT the canon: a gap, an arch note, a verdict, a note on one edge |

**A UID's prefix names the type a node was BORN with, not the type it is**
(`DEC-UID-OUTLIVES-TYPE`). The migration of 2026-08-30 retyped `SLICE-` to WORK,
`INV-` to REQUIREMENT and `SPIKE-` to EVIDENCE or WORK, changing only the
element tag, and a MECHANISM re-read as a REQUIREMENT keeps `MECH-`. Read the
tag (`_NODE_TYPE` in the export), never the prefix. `scribe new` requires the
current prefix on a NEW node; `scribe check` prints a `NOTE` per retyped node
and never fails on one. A retype records itself in the node's NOTES.

`COMMENTARY` is new and NOTHING IN THE CORPUS IS ONE YET
(`DEC-COMMENTARY-IS-THE-FIFTH-FAMILY`, open). It carries `STANDING` (open /
closed / withdrawn), a required `CLOSES_ON`, and an optional `EDGE` naming one
relation as `<FROM> <ROLE> <TO>` -- both ends of which must ALSO be `Remarks_On`
targets, which is what lets the parser refuse a dangling one.
`strictdoc-commentary-check` gates all of that. It does NOT retire the row
bracket: 494 rows still use it.

`STATUS` lives on DECISION only (`open` / `accepted` / `rejected` /
`superseded`). Every other type carries `DEPTH`.

Relation roles, and the direction they are written: a **Parent** role is written
on the node that DEPENDS -- `Governed_By` (→ a DECISION), `Guarantees` (→ a
REQUIREMENT), `Serialized_By`, `Proven_By` (→ EVIDENCE, from any type),
`Assumes`, `Crosses` (WORK → MECHANISM, the lane), `Covered_By` (USE_CASE → what
enables it), `Cites` (NARRATIVE → what it presents), `Superseded_By` (DECISION →
DECISION, on the retired one), `Backlogged_In` (→ a plan's backlog register),
and `File`. A **Child** role is written on the node that OWNS, pointing down,
and is never a dependency: `Contains` (NARRATIVE → its parts, in RELATIONS
order) and `Produces` (WORK → the EVIDENCE it left).

## Narratives and views

A NARRATIVE is how the canon is read by a person; the view system that renders
it lives in `docs/plans/whiteboard-view/`. Its `WIDGET` (`prose`, `rows`,
`table`, `glossary`, `legend`, `tally`, `edges`) says how to draw its STATEMENT;
`TAGS` are free facet words. Under `rows`, a STATEMENT holds `- ` items with an
optional trailing `[WORD]` or `[WORD: by]` bracket whose words come from the
root's `legend` child, never from the renderer. Cross references inside a
STATEMENT are `[LINK: UID]`, resolved and refused if dangling; in a TITLE the
same text is inert, so never put one there. A narrative presenting a plan's
nodes lives in that plan's directory — `Cites` is a Parent relation and
`INV-NO-EXTERNAL-PLAN-REFS` forbids one into another plan, so cite other plans'
nodes with `[LINK:]` only.

## The four governance fields

- **`DEPTH`** — `sketch` / `needs-design` / `needs-spike` / `interface-settled`
  / `implemented` / `verified`. Declares intent. The `needs-*` values are the
  design worklist. `implemented` means code landed and is **unreviewed**;
  `verified` means an independent session checked the code against the node.
  **The gap between them is the review queue** — `DEPTH == implemented` is the
  query.
- **`AUTHORED_BY`** — `llm` / `llm-accepted` / `llm-adopted` / `human`, a ladder
  that only rises (`DEC-AUTHORSHIP-LADDER`). Who wrote the statement, and how
  far a human has taken it on. The writer stamps `llm`; the other rungs are a
  human's acts.
- **`PARENT_FP`** — `<PARENT-UID>:<hash>` per parent whose contract this node
  depends on. Fingerprints point strictly **downward** (`DECISION` → `MECHANISM`
  → `WORK` → `NARRATIVE`), so a collectable node never strands an inbound one. A
  `0000000` entry DECLARES a dependency and may be written by the node's author;
  a hash is a signature and is the operator's.
- **`RETIRES_ON`** — required on `DECISION`. The forcing function. A deferred
  decision with no retirement condition is avoidance, not deferral.

Readiness is **not** a field. It is a query: a slice is implementable when every
mechanism in its closure is `interface-settled` or better, every decision in it
is `accepted`, and no edge is suspect. The `open` decisions in that closure are
the slice's degrees of freedom.

## Write with `scribe`, not with the edit tool

`scribe` is this repository's writer for the graph (SLICE-SDOC-CLI). **Its
option surface is DERIVED from the grammar** — one flag per field a node type
declares, one per relation role it may make — so `scribe new DECISION --help`
and `scribe new NARRATIVE --help` print two different surfaces, and neither can
be got wrong from memory.

```bash
scribe new MECHANISM --help          # the flags MECHANISM actually declares
scribe new MECHANISM --uid MECH-THING --title "..." --depth sketch \
     --statement @statement.md --path docs/plans/<plan>/
scribe set MECH-THING --depth implemented --notes @notes.md
scribe relate MECH-THING --role Governed_By --target DEC-SOMETHING
scribe relate EV-THING --role File --target devenv.nix \
     --element function --id 'tasks."strictdoc:bench"'
scribe show MECH-THING               # the node, with relations resolved to titles
scribe list --type WORK --depth sketch
scribe check                         # every node, relation and File path
scribe semantics DECISION            # the lifecycle a state field claims
```

Every writing verb takes `--dry-run`: `new` (including every type leaf), `set`,
`relate`, `unrelate`, `move`, and `delete`. It performs the same validation as a
real write, then prints a path-by-path unified diff of the bytes it would write;
`move` prints the rename it would perform. A move preserves the file's bytes,
but both its dry and real paths render and reparse the source before the rename,
so either refuses a document that does not round-trip. An empty diff reports
that nothing would change. A dry run writes no files and leaves the daemon's
held state unchanged. Every field flag takes **`@FILE`** to read the value from
a file and `-` to read it from stdin — which is how a multi-paragraph
`STATEMENT` gets in without a shell-quoting accident.

What the tool does that hand-editing does not: it validates against the grammar,
writes **canonical form through strictdoc's own writer**, then reloads the whole
graph to prove it still parses — **restoring the original bytes if it does
not.** A command that cannot validate leaves no changed file behind, and
`format` afterwards is no longer a step.

Two fields have **no flags at all** and that is the enforcement: `AUTHORED_BY`
and `PARENT_FP` are the operator's (MECH-RUNTIME-WRITE-GUARD). Naming one exits
non-zero saying who owns it. There is no override.

`scribe` needs a dev shell and the resident daemon up; `docs/sdoc/README.md` has
the start, stop and restart recipe, the board, the checks by name and the export
benchmark. `scribe semantics` is the one verb that runs with the daemon down: it
prints the lifecycle each state field CLAIMS — states, transitions, and rules
marked settled or open — and enforces nothing.

## Source linking is on

`strictdoc_config.py` enables `REQUIREMENT_TO_SOURCE_TRACEABILITY`, so relations
cross between the canon and the tree in both directions.

**Forward, from a node.** A `File` relation may name an item INSIDE the file:
`ELEMENT` (`function` or `class`) with `ID`, the qualified name as the reader
writes it, or `LINE_RANGE` instead of that pair. Write it with
`scribe relate --role File`, which refuses an id the file does not offer, and
`strictdoc-element-check` re-checks the corpus in `nix flake check`. Resolve an
id first — strictdoc drops one it cannot resolve at exit 0 with no marker:

```bash
strictdoc-grammar-extract dev/scripts/sdoc_extractors/__main__.py [--id NAME] FILE
```

**Backward, from code.** A `@relation(<UID>, scope=function|file)` marker in a
comment names the node from the source side. **The marker must be the FIRST line
of its comment block** — a later line carries its indentation, and an indented
marker does not match the marker grammar. It fails SILENTLY: exit 0, nothing
registered.

Only what `SOURCE_EXTRACTORS` matches is parsed for items
(`dev/scripts/sdoc_extractors/registry.py`: `**/*.nix`, `**/*.sh`, three named
extensionless scripts). Everything else gets a null reader, so a whole-file
relation to it resolves and no item inside it does.

## Required loop when you edit a `.sdoc` by hand anyway

`scribe` covers node and relation writes. For anything else — the `[DOCUMENT]`
header, a bulk fix across many files — the old loop applies:

```bash
SD=$(command -v strictdoc)
"$SD" format .                                    # canonical form BEFORE hashing
"$SD" export . --formats=json --output-dir build  # parse == validate; exit 0 required
```

Validation is not a separate command — it runs at parse time, so any export
validates. Non-zero exit means the graph is broken; do not proceed. `format`
takes no `--output-dir`, writes `./output/` unconditionally, and rewrites
`.sdoc` only — it is not the grammar's formatter.

## Hard rules

1. **UIDs are hand-chosen and semantic.** `MECH-SDOC-LEAN-FORMATS`, not `MECH-7`
   — the operator's 2026-08-27 ruling, because they read rendered views and an
   index is a handle they cannot dereference. The UID is also the filename. **Do
   not run `strictdoc manage auto-uid`**: it mints prefix-plus-counter, the form
   nobody here keeps.
2. **Never hand-write a node from memory — use `scribe new`.** Field order and
   blank-line rules are what get subtly wrong, and the tool takes both from the
   grammar rather than from your recollection. It also refuses a UID whose
   prefix does not match the node type, which strictdoc itself does not check.
   `strictdoc manage new` works here but mints a `MECH-1` UID rule 1 forbids and
   fills required fields with `TBD`, which parses clean. Do not use it.
3. **Never change a `PARENT_FP` hash.** Only a human accepts a contract change;
   the hash transition in a commit is the signature. An agent that clears its
   own fingerprints is a rubber stamp. Adding a `0000000` entry for a parent a
   node you author cites is a declaration, not a signature.
4. **Never edit an accepted `DECISION`'s `STATEMENT`.** Set its `STATUS` to
   `superseded`, add `Superseded_By`, and write a new decision.
5. **Always `format` before hashing** — unless `scribe` did the write, which
   already emits canonical form. It does not rewrap prose _today_, since
   `strictdoc_config.py` sets no `document_line_width`. Run it anyway:
   MECH-TREEFMT-SDOC would set that width, and a fingerprint taken over
   unformatted text would then churn on its own.
6. **Never set `AUTHORED_BY: human`.** It records who wrote the statement, and
   only the operator turns that key — at pull-request review, not here.
7. **Commit as you go, unprompted.** One commit per unit of work, not one at the
   end and not only when asked — the branch is long-lived and gets restacked
   into pull requests, so commit boundaries are what make that restack legible.
   Update the node in the same commit: raise its `DEPTH`, record measured
   numbers in `NOTES`, file what a probe found as `EVIDENCE`.

## Gotchas that fail closed

- **Field order is enforced.** Node fields must appear in grammar order. When
  extending the grammar, **append** — inserting mid-list means repositioning the
  field in every existing node. Extend it in
  `packages/strictdoc-grammar/values.nix` and regenerate; the `.sgra` is output.
- **Relation order inside a node is NOT enforced**, unlike field order —
  measured 2026-08-27. The role itself IS checked: an unregistered one fails
  with `Requirement relation type/role is not registered`. Keep relations in
  grammar order anyway so `format` diffs stay quiet.
- **One blank line between nodes**, and **no blank line between grammar
  elements**. Both are parse errors.
- **A `TAG:` starting with `SECTION` will not parse** — it collides with the
  built-in `[SECTION]`. Treat `SECTION*` as reserved.
- **A `File` relation carries `VALUE`, and may carry `ELEMENT` + `ID` or
  `LINE_RANGE`** — see "Source linking is on" above. What it must NOT carry is a
  `ROLE:`, which parses clean under `TYPE: File` and means nothing; only a
  `REVERSE_ROLE:` is a hard grammar syntax error. Write these through
  `scribe relate`, which validates the id; the parser does not.
- **`format` and `export` write a cache into `./output/` by default.** Pass
  `--output-dir` to `export`; `format` cannot be redirected. Never `git add -A`
  after running either from the repo root. `STRICTDOC_CACHE_DIR` is read BEFORE
  the config value and asserts the literal `Output/_cache`, capital O — it is a
  way to undo the config's cache path, not to relocate it.
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
- **The scribe daemon never reloads Python.** It imports everything under
  `dev/scripts/` once, at startup, so an edit there changes nothing until
  `devenv processes restart scribe` — and nothing warns you that you are running
  the old code. A broken import is louder but misleading: every `scribe` call
  then fails with a JSON-RPC `-32002` naming `strictdoc_config.py`, which reads
  like a broken corpus and is not one.

## Verifying — prove the test tested what you think

Running a command is not evidence until you know it exercised the thing you
meant. Two failures of this happened while building the current tooling: a
search returned no `.sdoc` results because `PYTHONPATH` shadowed the binary
under test, so the working code was never run (`MECH-SEMBLE-TEST-RECIPE`); and a
cycle injected to test cycle detection broke the file's syntax, so the export
failed for an unrelated reason while the grep matched "cycle" in prose.

So: **a negative result needs a positive control as much as a positive one
does.** Before reporting that something does not happen, show the same harness
detecting it when it should.

## Backlog protocol — applies to planning AND implementation sessions

This protocol and its three siblings on bringing anything to the operator live
in `docs/spec/`: `INV-DECISIONS-ARRIVE-AS-CARDS`, `INV-FILE-DO-NOT-NARRATE`,
`INV-LISTS-WHERE-THE-READER-UNPACKS`, `INV-SETTLED-STAYS-VISIBLE`.

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
- **File it against the plan's backlog register.** A new item carries
  `Backlogged_In` to `MECH-BACKLOG-<PLAN>` — the linchpin node every ungroomed
  item in that plan points at. The register holds no list; the edges are the
  list. See `DEC-BACKLOG-IS-A-REGISTER-NODE`.
- **That edge does not use up the item's parents.** Give it `Governed_By`,
  `Crosses`, `Assumes` to whatever it actually relates to as well. Containment
  by edge composes; containment by file did not. A web is the point.
- An ungroomed item is an ordinary node at `DEPTH: sketch` — a `MECHANISM` to
  build, a `DECISION` to make, a `WORK` item to do. **There is no `BACKLOG` node
  type**, deliberately: the existing types already say what kind of work it is.
- **Grooming no longer moves a file.** It raises the node's `DEPTH` in place and
  drops the `Backlogged_In` edge. A plan's ungroomed set is the register's
  inbound `Backlogs`; `DEPTH == sketch` scoped to the directory is worth keeping
  as a **cross-check**, since the two disagreeing means somebody filed without
  attaching or groomed without detaching (`MECH-SDOC-LAYOUT-CHECK`).

The operator's judgment budget is the scarce resource. A logged finding is not
lost; mentioning it costs attention, logging it costs nothing.

## What exists, and what still does not

Suspect-link detection, the readiness query and a derived view shipped on this
branch, and `scribe` shipped with milestone two (SLICE-SDOC-CLI). The gates all
of it is wired into are listed by name in `docs/sdoc/README.md`. `scribe`
applies **no instance semantics** — whether `DEPTH` may regress, when deleting
is legitimate and who may sign are milestone five's, and `delete` exists in the
tool precisely because this skill is what does not teach it.

What is still true: **nothing has ever been signed.** Every fingerprint entry is
a placeholder, so no contract change has been accepted by anyone. The parser
proves an edge resolves, never that its two ends agree. Say so plainly rather
than implying the canon is verified.
