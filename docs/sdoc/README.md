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

## Where this stands — 2026-08-27 (end of session 2)

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

Graph at close: 160 nodes, 0 suspect fingerprints, 0 cycles, 35
interface-settled, 80 sketch.

### The one thing still open for the operator

The roadmap's frozen statement promises milestone one delivers a gate at commit
time and in CI. Only CI exists. Its STATEMENT is fingerprinted, so correcting it
is either a supersession of an accepted decision or a contract change that makes
five nodes suspect and gets signed at pull-request review.

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

> Implementing `<SLICE-UID>` from the strictdoc design graph. Branch
> `feat/strictdoc-trial`, worktree at `<worktree path>`. Invoke the `sdoc`
> skill. Read that slice and everything it `Crosses` before starting. **Never
> run `fp-accept`** — signing a contract is the operator's key, and an agent
> commits under the operator's name, so an agent signature is indistinguishable
> from a real one afterwards. Use a fixture to exercise it. Commit as you go and
> update the nodes in the same commit. Log incidental findings to the plan
> backlog rather than telling me.

Give it a slice UID, not a description. The slice's closure is the brief, and
the graph already says whether it is ready.

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
