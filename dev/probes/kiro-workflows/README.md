# Kiro workflow-engine probe fixtures

The instruments behind `dev/references/kiro-workflows.md`. Dev-only: nothing
here is exported from the flake or referenced by a build.

They are kept because §12 still lists open questions, and re-deriving a probe
harness costs far more than reading one. Each file names the finding it produced
so a future session can extend rather than rebuild.

## Prerequisite

The engine is dark-shipped and off by default — see §1.1. Without
`ai.kiro.unlockedRolloutFeatures = ["workflows"]` the workflow tools do not
exist and nothing here is runnable.

**The probe root must be inside the workspace root** (§7.1). A `fileCheck` path
outside it evaluates false forever, silently, and a git worktree is a _sibling_
of the checkout and therefore outside. `.agents/probe/` in the primary checkout
works; `.agents/` is not gitignored, so delete the scratch before committing —
but keep these fixtures.

## Instruments

| file         | what it is for                                                          | findings   |
| ------------ | ----------------------------------------------------------------------- | ---------- |
| `counter.sh` | counts real invocations, to diff against engine iterations              | §7.2, §4.4 |
| `mark.sh`    | timestamped start/end marker; start-without-end reveals a killed branch | §7.7, §5.1 |
| `record.sh`  | logs each interpolated argument's length _and_ value separately         | §3.3, §7.3 |

The length/value split in `record.sh` is the non-obvious part: an empty captured
output is invisible if you only check that _something_ arrived, because the
injection envelope arrives either way (§7.3).

## Generators

Each writes `*.workflow.json` files to launch by absolute path via
`run_workflow`. All but `gen-stop-condition.py` take the probe root, since their
prompts name it; that one takes only an output directory, because every path it
emits interpolates a workflow input instead.

```bash
PROBE="$(git rev-parse --show-toplevel)/.agents/probe"
mkdir -p "$PROBE"
cp dev/probes/kiro-workflows/*.sh "$PROBE"/

python3 dev/probes/kiro-workflows/gen-fanout.py         "$PROBE"
python3 dev/probes/kiro-workflows/gen-join-policy.py    "$PROBE"
python3 dev/probes/kiro-workflows/gen-ref-probe.py      "$PROBE"
python3 dev/probes/kiro-workflows/gen-roster.py         "$PROBE"
python3 dev/probes/kiro-workflows/gen-stop-condition.py "$PROBE"
```

| generator               | shape                                                                           | findings   |
| ----------------------- | ------------------------------------------------------------------------------- | ---------- |
| `gen-fanout.py`         | one step, or several in `parallel`, each fanning out to N marker leaves at once | §3.6, §6   |
| `gen-join-policy.py`    | three runs differing only in `joinPolicy`                                       | §7.7       |
| `gen-ref-probe.py`      | two runs differing only in model                                                | §3.3, §7.3 |
| `gen-roster.py`         | one `parallel` of nine agents, `allSettled`                                     | §3.6, §5   |
| `gen-stop-condition.py` | two `repeat` nodes differing only in the file they watch                        | §7.1       |

**`gen-ref-probe.py`'s output has a launch-time requirement: run it with the
workflow input `workdir` set to the SAME directory you passed as `<probe_root>`
at generation time.** Its step prompts hardcode the generation-time root, while
its step `artifacts` map and its `completion` fileCheck interpolate the
`workdir` input. Pass anything else and the probe writes to one directory and
checks another: the fileCheck never sees its file, and the run fails looking
like an engine defect rather than a launch mistake. Generation cannot catch it,
because the mismatch is introduced later, at launch. The generated file now
carries the requirement in its own `description` field so it travels with the
artifact.

That applies to `gen-ref-probe.py` **alone** — the other four were checked.
`gen-fanout.py`, `gen-join-policy.py` and `gen-roster.py` declare no workflow
inputs at all and hardcode every path, so they have no second source of truth
and cannot diverge this way; `gen-stop-condition.py` sits at the other end and
interpolates `probe_dir` into every path it emits, prompts included, so it has
only one source of truth and its output directory need not be the probe
directory at all (its usage is `<out_dir>`, not `<probe_root>`). The difference
is not an inconsistency to tidy up: `gen-ref-probe.py` exists precisely to
exercise template-variable artifacts and completion interpolation (§3.3), and
that requires a workflow input.

**`gen-stop-condition.py`'s requirement is arming rather than agreement, and it
is the whole probe.** Before launching, create `<probe_dir>/pre-satisfied.json`
holding `{"complete": true}` and verify `<probe_dir>/never-written.json` is
**absent**; `probe_dir` must be inside the workspace root, since a `fileCheck`
outside it is false forever (§7.1) and the control would then reach its cap for
the wrong reason. The point of the probe is that the first stop condition is
satisfied _before its loop has run_, so a file the run itself writes measures
the ordinary stop-on-success path instead. Clear any stale `hits-a.log` /
`hits-b.log` too, or the line counts are unreadable. The requirement travels in
the generated file's `description`.

The predictions are 1 iteration for `repeat-pre-satisfied` and 2 — its cap — for
`repeat-control`, and the pairing is what makes either number mean anything. A=1
with B=2 is §7.1's do-while finding. A=1 with B=1 says instead that this shape
never exceeds one iteration whatever its condition is — that `maxIterations: 2`
grants nothing — which is the one reading A=1 cannot rule out by itself, and the
only job the control has. (An idle harness needs no control to exclude: it
produces no iteration wrapper and no log line at all.) A=2 would refute the
finding.

Read the iteration counts from the engine node tree (§4.4) **and** from the log
line counts, and prefer the node tree where they disagree: a step agent can
complete an iteration without doing any work (§7.2), which is a real confound
here because these prompts deliberately carry no anti-skip wording, so a log one
line short has two possible causes while a missing iteration wrapper has one.

Its steps name `general-task-execution`, which is the one place in these
fixtures a step agent is not a `wf-*` agent or a profile from `agents/`. The
name resolved and the steps ran, which is worth noting against §3.5's roster
listing it among the orchestrator-side subagent modes; nothing here measures
whether the step surface treats it any differently.

`gen-fanout.py`'s signature is `<probe_root> [out_dir] [count] [sleep] [steps]`,
and both counts are parameters rather than constants. `count` is the leaves per
delegating step, so a plateau can be re-confirmed at a larger N without editing
anything — which is exactly how the peak of 5 was checked at N=8 and then again
at N=12 (§6). `steps` is the one that settled what the 5 is scoped to: two
dispatchers at `count=5` peaked at 10, so the ceiling belongs to each delegating
step rather than to a pool they share (§6, finding 3). Above 1 it wraps the
dispatchers in one `parallel` under `joinPolicy: allSettled`, never `all`, which
would cancel the surviving dispatcher the moment one branch failed (§7.7) and
truncate the overlap window being measured.

`gen-roster.py` also creates the `roster/` directory its step agents write into.
That is load-bearing rather than tidiness: an absent file is only evidence of
"this agent has no file-write tool" if the directory it would have written to
definitely existed.

## Agent profiles

Custom step agents, in `agents/`. They are instruments like the `*.sh` files
above, but they install somewhere else: a Kiro agent profile is only registered
from `.kiro/agents/` at the workspace root, so these are copied there rather
than to the probe root. Each takes its token and its absolute output path from
the step prompt, so nothing in the file needs editing. The dispatch chain
additionally takes a CHAIN — the ordered list of agent names below the one being
prompted — and each link forwards that list minus its own next hop, so the chain
is self-describing and only the top of it needs a prompt:

```
TOKEN=<fresh token> PATH=<absolute path> CHAIN=probe-dispatch-nowrite probe-echo-leaf
```

An earlier revision had each link expect the bare NAME of its successor, which
made the chain depend on the launcher knowing the leaf and injecting it through
the top link's prompt — the fixture could not describe its own shape.

```bash
ROOT="$(git rev-parse --show-toplevel)"
mkdir -p "$ROOT/.kiro/agents"
cp dev/probes/kiro-workflows/agents/*.md "$ROOT/.kiro/agents"/
```

`.gitignore` covers `.kiro/hooks/`, `.kiro/settings/`, `.kiro/skills/` and
`.kiro/steering/` — **not** `.kiro/agents/`. Delete the installed copies when
the run is done, and keep the fixtures.

<!-- cspell:ignore nowrite  (a probe profile's file name, not project vocabulary) -->

| file                        | what it is for                                                                 | findings   |
| --------------------------- | ------------------------------------------------------------------------------ | ---------- |
| `probe-subagent-step.md`    | declares `subagent`; enumerates its delegation targets                         | §3.5, §3.7 |
| `probe-web-step.md`         | declares `web`; inventories its own tools from a step                          | §3.5, §3.6 |
| `probe-dispatch-parent.md`  | step-surface dispatcher holding `subagent` and nothing else                    | §3.7       |
| `probe-dispatch-nowrite.md` | middle relay of the same chain, likewise unable to write                       | §3.7       |
| `probe-echo-leaf.md`        | the leaf; writes a supplied token to a supplied absolute path                  | §3.7       |
| `probe-fanout-parent.md`    | dispatcher holding `subagent` only; fans out to N leaves at once               | §3.6, §6   |
| `probe-shell-leaf.md`       | holds `shell` only; runs `mark.sh` once so its sleep opens a measurable window | §3.6, §6   |

Three groups, alphabetical within each: the two inventory probes, then the
dispatch chain, then the fan-out pair. The chain's three rows are in **dispatch
order** — parent, relay, leaf — rather than alphabetical, because a chain read
out of order is what the prose above has to spend a paragraph undoing. That is
the ordering standard's "sorted within categorical groups" clause, with the
groups named here since a table cannot show them.

The two inventory probes emit four machine-checkable lines — `COUNT=`, `TOOLS=`,
`WEB=` and `DELEGATION=` — to a file rather than to captured output, because a
captured output can be empty and is never raw (§7.3). Both carry the
ignore-steering line for the reason §8.2 gives.

**Withhold the capability; do not forbid its use.** The dispatch chain is the
sharp case. `probe-dispatch-parent` holds `subagent` and nothing else — no
`write`, no `shell`, no spelling of "create a file" at all — so the token that
appears at the leaf's path can only have come from the leaf. An earlier version
of this probe gave the parent `write` too and could not distinguish "the leaf
ran" from "the parent wrote the file itself despite being told not to"; the
parent's own `DISPATCH=ok` line is not evidence either way. Two capability-free
relays in a row is what makes §3.7's result airtight rather than suggestive.

### These five are reconstructions, and they are now validated

The originals were throwaway files, written straight into `.kiro/agents/`, never
tracked, and deleted in cleanup. They are unrecoverable. What is committed here
was rebuilt from the declarations recorded in §3.5 and §3.7 — the `tools:` lines
are those recorded values, and the prompts and `permissions:` blocks follow the
conventions of surviving profiles elsewhere rather than any preserved original.

**They have since been re-run, and they reproduce.** All five were installed and
driven as one-step workflows on `claude-haiku-4.5`:

- `probe-subagent-step` returned §3.5's figures exactly — 30 tools, 15 real
  delegation targets (5 custom + all 10 bundled, self-inclusive).
- `probe-web-step` returned a self-consistent 17: `COUNT=17` with 17 names on
  its own `TOOLS` line, matching §3.5's transcription name for name.
- The three-link chain ran end to end with a token generated moments before and
  the target path verified **absent** beforehand. The file appeared holding
  exactly that token, and neither the parent nor the relay has a write tool, so
  §3.7's third tier is re-proved rather than merely re-asserted.

So the table above is a claim that a fresh run returns the same figures, not
only a map from profile to finding. The document's provenance labels still
belong to the original measurement; what these files now carry is an independent
confirmation of it.

The one figure that did **not** reproduce was wrong in the record: §3.5 read
`COUNT=18` for the `web` profile against a transcription of 17 names, and that
gap was recorded here as an open question — a name lost in transcription, or a
miscount. It was the miscount. The re-run's 17 names match the transcription
exactly, so nothing was ever missing, and §3.5 now reads 17.

**These profiles carry `permissions:` rule blocks that the originals were never
recorded as having.** That is a deviation from the instrument being
reconstructed, and it is **retained deliberately**: the validating runs above
included those blocks, and the inventories they returned are the recorded ones,
so the blocks demonstrably do not alter what a profile's declared groups expand
to. Stripping them now would trade a known-harmless deviation for a fixture with
no validating run behind it, which is the worse of the two.

The runs also exposed two defects in the prompts themselves, fixed in the
committed copies; the method rules below say what they were. The fixes touch
only how the four output lines are defined and how the chain names its next hop
— neither the `tools:` declarations nor the withheld-capability structure moved.

**The fixed copies were then re-run in turn**, so what is committed here is the
validated revision rather than an edit with no run behind it.
`probe-subagent-step` answered `WEB=no` — the defect it previously got wrong —
with 30 names on `TOOLS` and exactly 15 on `DELEGATION`, `subagent_response` now
excluded by name; `probe-web-step` again returned a self-consistent 17 with
`DELEGATION=none`, so the pair no longer counts the same thing two ways; and the
chain re-proved itself against a second fresh token, launched with only a CHAIN
and no injected leaf name. This second pass is the one that matters: the first
validated prompts that these files no longer contain.

### The fan-out pair is not a reconstruction

`probe-fanout-parent.md` and `probe-shell-leaf.md` were written for the width
measurement itself, and they are the files every run behind §6's finding 3
actually used: three runs on `claude-opus-5` — one dispatcher at N=8, one at
N=12, then two dispatchers in one `parallel` at five leaves each — with peak
overlap 5, 5 and 10 in turn, and every leaf in all three (8, then 12, then 10)
writing both its start and its end marker. Their rows above therefore stand
differently from the five reconstructions rather than equally: the five are
fixtures revalidated by a later run, while these two are the original
instruments that produced the finding.

The parent is capability-starved deliberately, under the first of the Method
rules below — design each probe so a false result is detectable — and that
starvation is the whole design: it declares `subagent` and nothing else, so with
no `write` and no `shell` it cannot append to the marker log by any spelling,
and every line in that log is therefore attributable to a leaf rather than to
the dispatcher. Its `BATCHED=` self-report is a diagnostic for a serialized run,
not evidence of the count.

## Method rules that these encode

Learned the hard way; §13 has the full set.

- **Design each probe so a false result is detectable.** Forbid the agent from
  reaching the goal another way, and require a durable on-disk artifact. A
  self-report is not evidence.
- **Derive every summary line from raw output; never ask for the judgement.**
  `WEB=` was asked as a judgement, and `probe-subagent-step` answered `WEB=yes`
  reasoning, in the open, `WEB tools: code (has LSP/MCP web capabilities)`. That
  is neither a contradiction nor an impression — `code` does carry LSP and MCP
  capabilities, so it is a defensible reading. It is also wrong. A tool's
  network capability is not visible from its name, so asking any agent to
  classify its own tools invites answers that are wrong and well argued at once,
  and the summary line alone leaves a reader no way to tell those apart from a
  correct one. The error was catchable only because the full list sat beside the
  verdict in the same file, which is the whole argument for emitting the list
  and leaving classification to the analyst reading it: a derived field can be
  recomputed and audited, a judgement cannot. Both profiles now define `WEB=` as
  a function of the emitted `TOOLS` line.
- **Define the field so two probes cannot answer it differently.** `DELEGATION=`
  was specified as "tool names beginning with `subagent_`", which silently
  includes `subagent_response` — a name that matches the prefix and dispatches
  nobody (§3.6). One probe listed it and the other answered `none`, so one
  fixture pair produced two incompatible counts of the same thing. It is now
  defined as tools that dispatch another agent, with `subagent_response`
  excluded by name while still counting on `TOOLS` and in `COUNT`.
- **Trust the run's own evidence, not a host status line.** A one-step run that
  named a deleted profile was refused outright (§3.5), while the host TUI showed
  `agent "probe-subagent-step" not found, using "default"` — announcing a
  fallback that did not happen. The line does not clear, so it can be read long
  after the run that produced it, and taking it at face value would condemn
  every custom-agent figure in §3.5 as having run under a generic agent. The
  refusal, the artifacts and the step header's resolved agent name are the
  evidence.
- **Do not change two variables at once.** The `joinPolicy` and model probes
  each hold everything else fixed for exactly this reason.
- **Tell every step to ignore user steering** — it leaks into in-flight step
  contexts and crowds out the requested output (§8.2). Every prompt here carries
  that line.
- **`validate_workflow` executes nothing**, so schema questions are free. Only
  spend a run when runtime behavior is the question.
- **Never `sleep` waiting on a run.** `run_workflow` returns immediately;
  launch, end the turn, act on the completion notification — and treat that
  notification as _finished_, not _succeeded_ (§4.2).

## Not included

The upstream authoring specification embedded in `acp-server.js` (§13) is
deliberately **not** vendored here. It is ~24 KB of upstream text; §13 documents
how to extract it on demand instead.
