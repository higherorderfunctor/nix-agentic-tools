# The design graph — operator notes

Everything here is mechanics: how to restore a working setup and how to tee up a
session. The design itself lives in the graph, not in this file.

## Restore after a break

The work is on branch `feat/strictdoc-trial`, in a worktree beside the primary
checkout. Derive the path rather than typing it:

```bash
worktrees="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")-worktrees"
ls "$worktrees/strictdoc-trial"
```

**Restore the `sdoc` skill.** Until this branch merges, the skill is registered
in `devenv.nix` on the branch but not materialized in the primary checkout. Copy
it in — `.claude/skills/` is gitignored, so this dirties nothing:

```bash
cp -r "$worktrees/strictdoc-trial/dev/skills/sdoc" .claude/skills/
```

A `devenv shell` entry in the primary checkout may prune it, since devenv owns
that directory. Re-run the copy if the skill stops being offered. Once the
branch merges, devenv materializes it like the other skills and this step goes
away.

**Read the graph.** One command tells you where everything stands:

```bash
strictdoc export . --formats=json --output-dir /tmp/sdoc-out   # exit 0 required
```

**The `strictdoc` binary needs a devenv shell.** `devenv.nix` gates
`ai.strictdoc.enable` on `!isCI`, so the binary reaches `PATH` only through
shell entry — every bare `strictdoc` command in this file assumes you are in
one, or that you pass an absolute path to a built one.

That is the only thing shell entry is needed for. **Committing** from a worktree
does not need it: the prek hooks resolve their config from the primary checkout,
so a worktree that has never entered a shell validates exactly like one that
has.

## The vocabulary is migrated — read the tag, not the prefix

On 2026-08-30 the node-type families landed (`DEC-NODE-FAMILIES`, docs/spec):
REQUIREMENT, DECISION, MECHANISM, EVIDENCE in the definition grid; USE_CASE for
coverage; NARRATIVE for representation; WORK for work. Every legacy node was
retyped in place under `DEC-UID-OUTLIVES-TYPE`: the element tag changed, the UID
did not, so `SLICE-`, `INV-` and `SPIKE-` prefixes are history and a node's type
is its tag. The mechanism mood test ran the same day: 13 mechanisms are now
requirements, 18 are evidence, four are held for a ruling. The `sdoc` skill
carries the table.

**Glossary:** joint, checkpoint, scribe, sdoc, strictdoc, canon, beads — the
table is in the `sdoc` skill. "Surface" and "graph" are the two words NOT to
use.

## Where this stands — 2026-08-30 (session 8: the view system)

The operator read the render, approved a permanent view system and the grid
migration, and delegated first-pass decisions. Landed: the grammar (seven types,
`Cites` / `Contains` / `Covered_By` / `Produces`, the four-rung authorship
ladder), the in-place retype of 34 nodes, the scribe reading a node's type from
its tag, and four rulings in `docs/spec/` — `DEC-NODE-FAMILIES` (supersedes the
grid), `DEC-UID-OUTLIVES-TYPE`, `DEC-MIGRATE-BEFORE-BEADS`,
`DEC-VIEWS-ARE-REGENERABLE` (supersedes the in-session-viewer ruling). The view
system's own plan is `docs/plans/whiteboard-view/`; its root narrative is the
place to read next.

**The view pipeline is built** (`docs/sdoc/view/`: `wireline.py` emits one
versioned JSON payload per root narrative, `view-check.py` reports what
strictdoc does not check, `render.py` fills a content-blind template). Render
any root with

```bash
devenv tasks run --mode before view:render --input root=NAR-SEMANTIC-LAYER
```

(the root goes through devenv's task-input channel; `--` passthrough does not
exist here). Pages and payloads land under `output/view/`, gitignored. Four
roots exist: `NAR-CANON` (the spec root: systems, counts, types, edges, words,
whiteboards), `NAR-SEMANTIC-LAYER` (the whiteboard as a tree of narratives,
`docs/plans/strictdoc-tooling/`), `NAR-WHITEBOARD-VIEW` (the view system's own
design) and `NAR-MECHANISM-MOOD-REVIEW` (the mechanism sort: 27 retyped in
place, 4 held for the operator, 104 stayed). Published copy (private artifact, a
copy of `output/view/canon.artifact.html`; republish the same file to keep the
link): https://claude.ai/code/artifact/45b8f97a-2f88-411b-81dc-ff057ad17ba8 —
one page over the whole canon with the system switches. The first render of
2026-08-29 stays at
https://claude.ai/code/artifact/9cdae156-301a-4baa-8d20-585dd6125d4e as the
reference and is never republished. Locally:
`devenv tasks run --mode before view:render` writes `output/view/canon.html`
(open it from disk) and `devenv tasks run view:serve` serves it on loopback.

**What the operator owns next:** the four held mechanisms on the mood review;
the two open decisions in the view plan; and whether to sign any of the 464
placeholder fingerprints, which nobody has.

## Where this stands — 2026-08-29 (session 7: the render exists)

**The semantic layer is rendered.** `SLICE-SEMANTIC-LAYER-RENDER` is at
`implemented`; its NOTES carry the artifact link, the page's shape, the
measurements and the review that ran before hand-over. Nothing was settled — the
page says so on every screen — and no decision was brought. The next step is the
operator's: read the render, then ask for decisions as cards, one per turn. Do
not re-run the render prompt below; it is done. The generator lives outside the
repository (`MECH-RENDER-GENERATOR-OUTSIDE-REPO`, backlog).

## Where this stands — 2026-08-29 (end of session 6)

**Explored, nothing settled.** The session worked the hook layer and then
climbed to the semantic layer, and everything above the glossary is a sketch or
an open decision. 204 nodes, check clean.

What is durable from it:

- **Glossary rulings** (accepted, the operator's): `DEC-JOINT-NOT-SURFACE`,
  `DEC-SCRIBE-NAMES-THE-WRITER`, `DEC-CANON-NAMES-THE-COMMITTED-CONTENTS`. The
  table is in the `sdoc` skill.
- **Contributor-communication requirements** in `docs/spec/`, four `INV-` nodes:
  cards, lists, file-do-not-narrate, settled-stays-visible.
- **The hook layer as a snapshot:** `SLICE-HOOK-LAYER` →
  `MECH-HOOK-MIDDLEWARE-INTERFACE` → three open decisions
  (`DEC-HOOK-GRANULARITY`, `DEC-HOOK-SETTINGS-NAMESPACE`,
  `DEC-HOOK-TRIGGER-REPRESENTATION`). Scope the operator fixed: joints are CRUD
  through scribe, git through a normalized interface with prek as the shipped
  target, strictdoc's one hook, and devenv as the place hooks are declared.
  Harness-specific joints and CI are OUT.
- **The semantic layer, explored:** `SLICE-WORKFLOW-DSL` crosses
  `SPIKE-DSL-PRIOR-ART` (concept set, scope boundary, reading list), three
  candidate DSL shapes (`MECH-DSL-CANDIDATE-*`, same worked example each),
  `MECH-DSL-CONDITION-LANGUAGE`, and `MECH-SEMANTIC-LAYER-WHITEBOARD` — a
  one-sheet of every semantic the canon describes, each line tagged works /
  falls out / unaddressed / gap / open. `DEC-DSL-SHAPE` and
  `DEC-DSL-LAYER-COUNT` are open; layer count is deferred on purpose.
- **A lesson, filed as work:** `SLICE-SEMANTIC-LAYER-RENDER`. Three attempts to
  present the semantic layer as text failed — a graph does not survive being
  flattened. The next session renders it instead.

### What is open for the operator

Nothing that needs ruling before the render exists. Read the render, then the
open decisions come as cards one at a time.

## Where this stands — 2026-08-28 (end of session 5)

**The vocabulary has a shape now, and the layers have numbers.** Six decisions
and one classification landed today; nothing was implemented. 173 nodes, 0
cycles, 0 suspect fingerprints, export clean.

**`DEC-NODE-TYPE-GRID` is the one to read first.** Node types are derived from
two binary axes — normative or descriptive, universal or particular — and four
of the six fall out of the cross product. `DECISION` and `NARRATIVE` sit outside
because they act on the grid. It answers three questions that were being argued
one at a time: a design principle is a `REQUIREMENT`, a use case is its own type
and was the empty cell, and an imperative step is `WORK` and is not a claim at
all.

**`DEC-LAYER-STACK` numbers the layers and names the rule that was violated.**
L0 grammar machinery, L1 the grammar spec, L2 hook machinery, L3 semantics. Each
may use only what is beneath it, and **semantics are never written directly into
a tool**. Vertical slices cut across; a slice is how work ships, a layer is how
the system is reasoned about.

**The other four rulings.** One grammar, not two (`DEC-ONE-GRAMMAR`) — the
two-grammar sketch stays on disk, wired to nothing, as a written-out
alternative. Authorship is one monotonic four-value field governing reversal
rather than credit (`DEC-AUTHORSHIP-LADDER`). An open decision _is_ a question
(`DEC-OPEN-IS-THE-QUESTION`), flagged for re-evaluation because where contention
lives is still unproven. And `MECH-MILESTONE-TWO-SEMANTICS-MISPLACED` records
that milestone two's fingerprinting and readiness logic sits in the tool rather
than in L3 — **classification only, judgement on the logic deliberately
pending.**

That last node carries the worked example: of the four refusals milestone two
advertised, two are read off the grammar and are the layering working, and two
are rules baked into the script. The tell is whether a grammar change could
change the answer.

### What is open for the operator

**Everything the previous session left open is still open** — the roadmap's
unmet promise, and `DEC-NODE-FILE-NAMING` awaiting ratification.

**New, and the one that gates the most:** `DEC-PLAN-LIFECYCLE-OPEN` is narrowed
to retention only and still unratified. Its lean — once beads exists a plan is a
launch point rather than a record, execution lives in beads, and the committed
plan is an immutable snapshot taken at ingest — decides whether `PLAN` and
`WORK` survive as node types at all.

**Owed and not yet done:** `PLAN`, `WORK`, `USE CASE` and `NARRATIVE` are ruled
in but not in the grammar. Adding them is a `values.nix` edit and a regenerate.
`DEC-AUTHORSHIP-LADDER` likewise extends `AUTHORED_BY`'s word list, and who may
raise a value is unanswered — raising to `llm-accepted` is a human act with no
place to happen yet.

<details>
<summary>Prior — 2026-08-27 (end of session 3)</summary>

**The corpus is one node per file, and the backlog is a node rather than a
file.** 166 nodes, 166 files, each named for its node's UID lowercased. Every
ungroomed item carries `Backlogged_In` to its plan's register —
`MECH-BACKLOG-STRICTDOC-TOOLING` or `MECH-BACKLOG-BEADS-MIGRATION` — so the
backlog is reachable by traversal instead of by listing a directory, and an item
can carry its other edges at the same time. The ten multi-node documents are
gone, the numbered-file convention with them. No UID changed, so no edge moved
and no citation broke — proved rather than asserted: a per-node dump of the JSON
export is identical across the carve, and 0 of 161 contract hashes moved.
Reading one backlog item used to cost 279 KB; it now costs the node.

**Milestones two and three are READY. Nothing in either closure waits on the
operator.** Hand either to an implementation session by slice UID.

    SLICE-SDOC-CLI          milestone 2  READY
    SLICE-BEHAVIOUR-MODEL   milestone 3  READY
    SLICE-CHECKPOINT-WIRING milestone 4  blocked: DEC-PLAN-LIFECYCLE-OPEN, and m2
    SLICE-INSTANCE-SEMANTICS-MIGRATION  m5  blocked: the above + DEC-FP-ACCEPT-AUTHORITY

**Milestone one is `verified`**, raised after an independent session read the
node against the tree. Nine divergences were found, all nine survived a
refute/defend contest, and none were code defects — the implementation was sound
and the node's accounting was not. Its one unmet promise is tracked, not
forgotten: the governing decision says milestone one delivers a validation gate
at commit time AND in CI, and only CI exists.

**Milestone two's scope collapsed once the layers were separated.** The tool's
option surface derives from the grammar; it runs format and validation; that is
the milestone. Three questions raised against its draft verb list were ruled
INSTANCE SEMANTICS and moved to milestone five — whether deleting is legitimate,
whether raising `DEPTH` is a lifecycle move, and whether to ship the harness
denial given it is absent in eleven of twenty-three worktrees. `delete` exists
in the tool and the skill deliberately does not teach it. Denying direct edits
in the harness moved to milestone four, which owns checkpoints.

Graph at close: 166 nodes, 0 suspect fingerprints, 0 cycles, 38
interface-settled, 81 sketch. Five are new this session —
`DEC-NODE-FILE-NAMING`, `MECH-SDOC-LAYOUT-CHECK`,
`DEC-BACKLOG-IS-A-REGISTER-NODE` and the two backlog registers — and the count
read 160 before, which was already wrong by one against the same export.

### What is open for the operator

**The roadmap's unmet promise.** Its frozen statement promises milestone one
delivers a gate at commit time and in CI. Only CI exists. Its STATEMENT is
fingerprinted, so correcting it is either a supersession of an accepted decision
or a contract change that makes five nodes suspect and gets signed at
pull-request review.

**Two of the carve's three questions, applied but not ratified.** The naming
convention and the fate of the numbered-document convention were reserved for
you, and the carve had to answer both to run at all. They are recorded as
applied in `DEC-NODE-FILE-NAMING`, left at `STATUS: open` so ratification is
still yours. Render it and rule. The third — what a per-plan backlog becomes —
you ruled the same day, and it is settled below.

**Settled since, so it is no longer waiting on you.** `DEC-PLAN-SCOPED-BACKLOG`
described a 99-backlog document and grooming-by-moving, both false after the
carve, and an accepted statement is frozen. It did not need a waiver in the end:
its own `RETIRES_ON` names this exact situation — an item tracked while living
outside the plan's backlog document — and names the successor, an explicit
register node and a `Backlogged_In` role. The condition fired, so it is
`superseded` with its statement untouched, and `DEC-BACKLOG-IS-A-REGISTER-NODE`
is the successor it asked for.

</details>

## Teeing up a session

Both prompts assume cwd is the **primary checkout**. You do not need to `cd` to
the worktree; hand the agent its path and it edits there by absolute path.

### A planning / grooming session

> Planning session on the strictdoc design graph — **planning, not
> implementing.** Branch `feat/strictdoc-trial`, worktree at `<worktree path>`.
> Draft PR #1240 shows the diff from main.
>
> Invoke the `sdoc` skill. Read the `project_strictdoc_trial` memory for
> measured ground truth. Then export the graph and read it:
>
>     strictdoc export . --formats=json --output-dir /tmp/sdoc-out
>     python3 docs/sdoc/status.py /tmp/sdoc-out/json/index.json
>     python3 dev/scripts/fp-check.py /tmp/sdoc-out/json/index.json
>
> **I do not read raw sdoc.** Render what I need to weigh —
> `docs/sdoc/render.py --uid X` resolves edges to titles, which is the part I
> cannot see otherwise. Bring me decisions as plain-language cards, a few at a
> time.
>
> You own writes to the branch; no other session is running. Do not implement —
> if something wants building, slot it as a slice and hand it to a separate
> session. **Never run `fp-accept`.** Log incidental findings to the plan
> backlog rather than telling me.

The distinction that matters: a planning session **grooms, decides, and slots**.
It writes nodes and edges. It does not write code, and it does not sign.

### An implementation session

> Implementing `<WORK-UID>` from the strictdoc design graph. Branch
> `feat/strictdoc-trial`, worktree at `<worktree path>`. Invoke the `sdoc`
> skill. Read that slice and everything it `Crosses` before starting. **Never
> run `fp-accept`** — signing a contract is the operator's key, and an agent
> commits under the operator's name, so an agent signature is indistinguishable
> from a real one afterwards. Use a fixture to exercise it. Commit as you go and
> update the nodes in the same commit. Log incidental findings to the plan
> backlog rather than telling me.

Give it a WORK UID, not a description. The work's closure is the brief, and the
graph already says whether it is ready.

### The render session — DONE 2026-08-29 (kept for the record)

> Rendering session on the strictdoc design graph. Branch
> `feat/strictdoc-trial`, worktree at `<worktree path>`. Invoke the `sdoc` skill
> and read its glossary and its "grammar lags the rulings" table first. Then
> read `SLICE-SEMANTIC-LAYER-RENDER` — it is the brief — and
> `MECH-SEMANTIC-LAYER-WHITEBOARD`, which is the input.
>
> **Build an HTML artifact, not text.** Use the harness's artifact tool to
> publish a self-contained, mobile-first, theme-aware page that presents the
> semantic layer for the operator to reason over and judge: one screen per node
> type with fields separate from edges; the edges as a diagram; status as colour
> with a legend; the five top gaps on their own screen with the nodes they touch
> linked; every UID shown with its title. Only the ruled vocabulary
> (REQUIREMENT, USE CASE, MECHANISM, EVIDENCE, DECISION, NARRATIVE, WORK) —
> never the dissolved names. Nothing in it is settled; say so on the page.
>
> Do not present the semantic layer in chat. Hand over the link, then stop.
> Decisions come afterwards, as cards, one per turn, only for what the operator
> asks to settle. **Never run `fp-accept`.** Log incidental findings to the plan
> backlog rather than telling the operator.

The previous session's L2 brief is superseded by the snapshot it produced
(`MECH-HOOK-MIDDLEWARE-INTERFACE`); do not redo it.

### A side session in another agent (Codex, or any agent that reads AGENTS.md)

`AGENTS.md` knows nothing about this branch, so hand the bootstrap over in the
prompt. Give the session its own worktree first:

```bash
git worktree add -b feat/<slug> "$worktrees/<slug>" feat/strictdoc-trial
```

Then, in the prompt: read this file, the `sdoc` skill
(`dev/skills/sdoc/SKILL.md`: types, roles and their direction, the glossary, the
hard rules, the parser gotchas), `docs/sdoc/grammar.sgra`, and the rulings in
`docs/spec/`. Read the canon through the export, never by parsing files; one
node with its neighbours is `docs/sdoc/render.py --uid`; a whole view as JSON is
`docs/sdoc/view/wireline.py <index.json> <worktree> --all-roots` (nodes, edges,
backlinks, grammar, systems). The strictdoc and `sdoc` binaries live in this
worktree's `.devenv/profile/bin/`; another worktree can call them by absolute
path. The rules that bind every agent: write only your own plan directory,
register first; never a Parent relation into another plan; never `fp-accept`,
never a `PARENT_FP` hash, never `AUTHORED_BY`; supersede, never edit, an
accepted decision. The whole canon is not meant to be in a session's context:
`MECH-PARTIAL-VIEWS-FOR-A-BOUNDED-CONTEXT` is the gap.

### What a fresh session loads, and what it does not

**Automatic:** `CLAUDE.md`, `AGENTS.md`, the `MEMORY.md` index, and every
skill's one-line description.

**Not until told:** the body of `project_strictdoc_trial.md`, the graph
contents, and the `sdoc` skill body. The memory index carries a pointer, not the
content — which is what both prompts above are closing.

There is no automatic context-following by relation. Naming a plan or a slice is
the manual stand-in; `MECH-READY-QUERY` is the node that replaces it.

## Reading the graph

```bash
strictdoc export . --formats=json --output-dir /tmp/sdoc-out
J=/tmp/sdoc-out/json/index.json

python3 docs/sdoc/render.py $J                    # the grooming queue
python3 docs/sdoc/render.py $J --all              # everything
python3 docs/sdoc/render.py $J --uid <UID>        # one node plus its neighbours
python3 docs/sdoc/render.py $J --depth needs-design --depth needs-spike
```

Markdown on stdout — pipe it to a pager or open it in an editor. Every relation
and fingerprint prints with the **target's title**, not a bare UID, so reading a
node does not send you hunting for what it depends on. That resolution is the
only real work the renderer does, and it is most of what makes raw sdoc hard to
read.

`--uid` is also the bounded context packet in embryo: a node plus everything it
depends on and everything depending on it.

## Testing semble with the sdoc grammar

`cd` into the worktree and use devenv. That is the real integration test — it
exercises the wiring that ships, and devenv sets `PYTHONPATH` correctly by
construction.

```bash
semble search "your query" --content docs --max-snippet-lines 10
```

`--max-snippet-lines` matters: a raw chunk of a large node will flood a terminal
or an editor.

Automated equivalents:

```bash
nix build .#checks.x86_64-linux.module-semble-strictdoc-grammar-load
nix build .#checks.x86_64-linux.strictdoc-grammar-corpus
```

**Only if you need to test a customization that is NOT the one devenv installs**
do you have to build it by hand — and then `PYTHONPATH` becomes a trap. An
installed semble exports it, and it shadows any other build, so pointing at a
freshly built binary silently runs the installed one with the installed
mappings. Scrub it, and redirect the cache so the test does not invalidate the
real index:

```bash
env -u PYTHONPATH SEMBLE_CACHE_LOCATION=/tmp/semble-scratch "$S/bin/semble" search ...
```

## Standing gotchas

The full list is in the skill. The four that fail **silently**, and so are the
dangerous ones:

- `--filter-nodes` is ignored by the JSON exporter.
- Cycles among role-carrying relations are not detected — and nearly every
  relation here carries a role.
- Incremental export produces false greens; gates need a clean output directory.
- `manage new` pre-fills required choice fields with `TBD`, which parses clean.
