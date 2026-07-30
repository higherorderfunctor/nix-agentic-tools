# Agent profile probes

Mode **F** fixtures: agent definitions for the operator-driven runs. They are
inert on disk — installing them changes nothing until a live session dispatches
one.

**Lint before every run.** `../scripts/lint-probes.sh` refuses each hazard
below, and `../scripts/self-test-lint-probes.sh` proves it does by rejecting a
deliberately-broken fixture per rule. Exit 0 is clean, 1 is findings, 2 is
"could not run" — never read a 2 as a pass.

## Installing

```bash
cp fixtures/kiro-primitives/agents/profiles/* "<root>/.kiro/agents/"
```

The loader **walks that directory recursively** and keeps any entry ending `.md`
(YAML front matter) or `.json`. The id is the path relative to the agents dir
with the extension stripped and separators normalized, so `workers/drainer.md`
has id `workers/drainer`. **Symlinks are fine here** — that loader resolves them
and recurses through symlinked directories, with a visited set guarding cycles
and a warning on a dangling link. Do **not** carry that over to hooks: a
symlinked hook file is silently skipped. The two loaders disagree, and the
disagreement is load-bearing in both directions.

### Why the profiles live in `profiles/` and this file does not

"Keeps any entry ending `.md`" includes **this README**. The first version of
this directory kept the profiles and their documentation side by side, and the
linter rejected the README as a profile with no front matter. It was right: the
walker would have parsed it, thrown, and logged a dropped profile. The
installable tree therefore holds nothing but profiles, so the copy above cannot
carry documentation into `.kiro/agents/`. The linter names that specific mistake
if it ever recurs, rather than reporting "no front matter" on a file that was
never meant to have any.

## No profile sets `name:`

The effective id is `frontMatter.name ?? agentId`, so a `name` key overrides the
filename. Every profile here omits it, which keeps the filename the single
source of truth for the id and makes two hazards unreachable: a `name` that
collides with a builtin mode id even though the filename does not, and two files
that resolve to one id and silently shadow each other. The linter checks both
anyway.

## The four hazards these files avoid

| Hazard                           | What happens                                                                                                                                                         |
| -------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `allowedTools` / `toolsSettings` | **`.json` only.** A profile carrying either is **silently skipped** unless it also carries a non-null `permissions` — a debug log and nothing else. Prefer `.md`.    |
| A builtin-mode id                | `vibe`, `spec`, `quick-spec`, `bug-fix`, `plan`, `autonomous`. A collision **loads** and is then filtered out of the registry: not addressable while looking loaded. |
| A v2-shaped `hooks`              | v2's `hooks` is an OBJECT, v3's is an ARRAY. A mapping there fails validation and drops the **whole** profile, not just the hooks.                                   |
| `yes` / `no` / `on` / `off`      | Front matter is parsed with js-yaml's **CORE** schema, where these are strings, not booleans. In a boolean-typed field that is a type error and the profile drops.   |

Two more structural rules: a `.md` profile needs a `---`-delimited front-matter
block that parses to **at least one key** — zero keys, including a missing or
comment-only block, throws and the profile is dropped — and exactly one YAML
document per block. Everything else in both schemas is optional.

For a `.md` profile the **body is the prompt**, which is why all of this
commentary lives here rather than in the files. Front-matter comments are safe
(they are parsed, never prompted) and a few profiles use them for a one-line
note about a load-bearing key.

## The hook-gate pair

`probe-hook-gate-custom.md` and `probe-hook-gate-default.md` are byte-identical
except for the `dispatchKind` line:

```console
$ cd fixtures/kiro-primitives/agents/profiles
$ diff probe-hook-gate-default.md probe-hook-gate-custom.md
3c3
< dispatchKind: sub-agent
---
> dispatchKind: custom-agent
```

**Run that diff as a pre-flight.** If it reports more than one changed line, the
arms differ in something other than the variable under test and the comparison
is void.

`dispatchKind` is optional and defaults to `sub-agent`, so the negative arm
states the default **explicitly** — that is what makes the diff one line without
changing behavior. The default sub-agent adapter builds its child with
`skipHooks: true`, so the prompt and stop hook nodes early-return inside a
dispatched worker; the custom-agent adapter omits the flag entirely, and those
nodes run. It is not a hooks-only toggle: the same choice also flips
`includePreviousMessages` and changes the result-extraction shape.

Protocol, one arm at a time, with `probe-observed-prompt-submit` installed: note
how many records the probe log holds, dispatch one arm, count again. The
custom-agent arm adds a record for the dispatched worker; the sub-agent arm does
not. Use the prompt-submit probe rather than the stop probe for this — the stop
probe is one-shot per state directory and the root's own turn claims it first.

## The nonce pair

`probe-nonce-parent.md` mints a `PROBE-NONCE-<12 hex>` token at run time and
dispatches `probe-nonce-child.md` with it. The parent reports only
`NONCE-MATCH: yes|no` and never writes the token into its own reply, so the
token exists in exactly two places: the parent's dispatch input and the child's
reply.

That is the point. **Nesting cannot be verified from the display** — completed
dispatch nodes collapse into a summary that counts only direct children, so a
grandchild appears root-spawned, and that appearance once corroborated the false
belief that subagents cannot recurse at all. A token the root never emitted,
appearing in a grandchild's transcript, cannot be explained by a root-spawned
child. Verify by grepping the session transcript for `PROBE-NONCE-`: expect it
in the parent's dispatch input and the child's reply, and **absent** from every
root message.

The parent grants `invoke_sub_agent` explicitly because an agent with no `tools`
key gets **no tools at all** — the real reason an unmodified subagent cannot
nest is a missing grant, not an engine prohibition. Without that line the probe
silently degenerates into a one-level run, which looks exactly like the
prohibition it is meant to test.

## The drainer

`probe-drainer.md` sets `dispatchKind: custom-agent`, and that is a correctness
requirement rather than a preference. The drain loop primitive is a `Stop` hook
exiting 1, which injects script-authored text and restarts the graph; under the
default sub-agent adapter a dispatched worker's Stop hook never fires, so the
worker could not loop. The profile deliberately says nothing about queue format
— the drain protocol is unsettled, and this fixture fixes only the role's tool
grant and dispatch kind.

## The JSON arm

`probe-json-inspector.json` is the one `.json` profile. It exists so the
JSON-only rules are exercised against a real file rather than only against
synthetic fixtures, and it carries a `permissions` block and neither CLI-only
field.
