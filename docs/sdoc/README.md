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

Nothing else needs restoring. No devenv shell entry is required in the worktree
— commits from it work, because the prek hooks resolve their config from the
primary checkout.

## Teeing up a session

Both prompts assume cwd is the **primary checkout**. You do not need to `cd` to
the worktree; hand the agent its path and it edits there by absolute path.

### A planning / grooming session

> Working on the strictdoc design graph, branch `feat/strictdoc-trial`, worktree
> at `<path>`. Invoke the `sdoc` skill. Read the `project_strictdoc_trial`
> memory for measured ground truth, then export the graph to JSON and walk it. I
> want to decide what to design next versus what is good enough to implement —
> weigh what is undesigned that could still change things, and whether each is
> cheap to reverse. Log incidental findings to the plan backlog rather than
> telling me.

What a fresh session loads **automatically**: `CLAUDE.md`, `AGENTS.md`, the
`MEMORY.md` index, and every skill's one-line description. What it does **not**
load until told: the body of `project_strictdoc_trial.md`, the graph contents,
and the `sdoc` skill body. The prompt above is what closes that gap — the memory
index carries a pointer, not the content.

There is no automatic context-following by relation yet. Naming a plan directory
is the manual stand-in; `MECH-READY-QUERY` is the node that replaces it.

### An implementation session

> Implementing `<SLICE-UID>` from the strictdoc design graph, branch
> `feat/strictdoc-trial`, worktree at `<path>`. Invoke the `sdoc` skill. Read
> that slice and everything it `Crosses` before starting. Log incidental
> findings to the plan backlog rather than telling me.

Give it a slice UID, not a description. The slice's own closure is the brief,
and the graph already says whether it is ready.

## Layout

| path                                | holds                                                |
| ----------------------------------- | ---------------------------------------------------- |
| `strictdoc_config.py`               | the `@repo` grammar alias and the markdown exclusion |
| `docs/sdoc/grammar.sgra`            | the one grammar, shared by every document            |
| `docs/plans/<plan>/`                | a named plan, many files. Decays.                    |
| `docs/plans/<plan>/99-backlog.sdoc` | that plan's ungroomed items, at `DEPTH: sketch`      |
| `**/.sdoc/`                         | settled architecture beside the code it describes    |
| `dev/skills/sdoc/SKILL.md`          | authoring mechanics and the parser gotchas           |

## Where things stand

```bash
strictdoc export . --formats=json --output-dir /tmp/sdoc-out
python3 docs/sdoc/status.py /tmp/sdoc-out/json/index.json
```

Prints the node counts, the open decisions, what needs design or a spike, the
ungroomed backlog, which slices are ready to implement, and how many
fingerprints are still placeholders. Filtering happens in that script rather
than on the strictdoc command line, because `--filter-nodes` is silently ignored
by the JSON exporter.

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
