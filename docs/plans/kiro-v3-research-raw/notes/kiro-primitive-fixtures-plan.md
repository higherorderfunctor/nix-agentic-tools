# Kiro primitive fixtures — build plan

> **Status:** plan awaiting approval, 2026-07-29. Phase 1 has since landed as
> `fixtures/kiro-primitives/`; §6a's F1-F8 remain unexecuted and are the items
> the phase-2 digests in `../phase2/` (F9-F22) continue the numbering of.
> Preserved in this corpus 2026-08-04 with private references removed — the
> one lightly edited file here, see the corpus README. Companion to
> `kiro-wavefree-loop-design.md` (not imported), which holds the findings this
> plan turns into fixtures.

## 1. Goal

One session produced a large corpus of Kiro v3 mechanics, most of it undocumented
and read out of the shipped KAS bundle. **The corpus is the durable asset; the
wave-free drain design is one consumer of it.** This plan builds fixtures covering
**every primitive found**, so the discovery never has to be repeated.

Explicit scope from the operator:

- Cover **all primitives found**, not just the ones the drain design needs.
- Carry **negative paths and rejected designs** that were already found — they are
  often the expensive part. **Do not go hunting for more.**
- The committed form must be **general**: no reference to any private
  repository.

## 2. Three modes, cheapest first

Not every finding earns a runnable fixture. Operator: *"making replayable the
evidence is also acceptable if not worth a runnable fixture."* Each finding gets
exactly one mode, and the **selection rule is cost order**:

> **R before F, and C only when neither can hold it.**
> Use **F** only for behaviour that cannot be read from the bundle or replayed from a
> recorded command.

| Mode | What it is | Runs how | Cost |
| --- | --- | --- | --- |
| **R — replayable record** | what the finding establishes, the semantic anchor, a command that currently demonstrates it, its expected output, and the KAS version it was captured against | non-interactive, on demand | very cheap |
| **F — runnable fixture** | a scratch workspace, a prompt, an assertion | HITL, v3 TUI | 2-3 sittings |
| **C — carried negative** | belief / reality / how it presented | not executed | documentation only |

### 2.1 There is deliberately NO extractor or drift check

An earlier draft proposed a fourth mode: an extractor, a committed sidecar, and an
automated drift check modelled on the repo's typed-option extractors. **That is
withdrawn, and the reasoning is worth keeping so it is not re-proposed.**

- **The anchors are unstable generated identifiers.** `state2`, `graph3`,
  `userHookOnPromptsNode2`, `external_exports2` are **esbuild collision suffixes**,
  not minifier output — corrected 2026-07-30: the bundle is pretty-printed (~495k
  lines) and keeps original names, comments, and `// src/<path>.ts` section markers.
  The conclusion is unchanged, because collision suffixes still renumber as modules
  are added or removed, but the mechanism named here was wrong. A check keyed on them fires on cosmetic renames
  while behaviour is unchanged — a check that cries wolf, which this repo has already
  declined to ship once on exactly that ground.
- **Nothing consumes the output, so firing "earlier" changes no decision.** The
  existing extractors earn their automation because **config is generated from
  them** — a stale option enum produces a broken module. A stale behavioural note
  produces a note that gets re-read anyway. Different stakes; the automation does not
  transfer with the pattern.
- **The access pattern is deliberate, not continuous.** The realistic sequence is:
  months pass, the fixture is revisited, someone asks "is this still true?" At that
  moment a recorded command is *exactly as good* as a drift check would have been.
- **The one real risk was already covered by R.** The worry worth having is that a
  future re-read greps, finds nothing, and concludes "the feature was removed" when
  the bundle merely moved. The remedy is **positive controls recorded in the record**,
  not automation.

**What must survive is the part a regex cannot hold: the semantic anchor.** A record
that says only `grep 'userHookOnPromptsNode2'` is worthless the moment the minifier
renumbers. A record that says *"the early-return on `skipHooks` at the top of the
prompt-hook graph node — here is the command that found it in 2.15.1"* stays useful,
because a human can re-locate it by meaning. **The command is disposable; the
semantics are not.** Every R record is written that way.

### 2.2 When automation WOULD become warranted

One concrete trigger, so this is a condition rather than a vague "maybe later":
**when a finding stops being evidence and becomes config.**

`dispatchKind` is the live example. It is a real agent-profile field, and if this repo
grows a typed Kiro `agents` surface — which config parity eventually requires — then
`dispatchKind` becomes a typed option whose staleness produces a **broken module**,
not a stale note. At that point it belongs in the existing extracted-surface family,
extracted from the binary and drift-checked like every other option enum. Not before.

## 3. Mode R (part 1) — code-read records

One record per invariant, in `fixtures/kiro-primitives/records/<group>.md`. Each
states **what it establishes**, the **semantic anchor** (what the code does, in
words), a **command that demonstrated it** against KAS `2.15.1-e20633b4…`, and the
**expected output**. Locating the bundle is itself a recorded step: resolve
`kiro-cli` on PATH, then its `kas/<version>-<hash>/` sibling.

**Two writing rules**, both from §2.1: never let a minified identifier be the only
handle on a finding — describe it semantically first; and record byte offsets only as
a convenience note, never as the anchor, since they move on every rebuild.

| Group | Invariant established | Semantic anchor (command is a convenience, not the record) |
| --- | --- | --- |
| concurrency | max concurrent subagents = 5 | `MAX_CONCURRENT_SUBAGENTS` binding + its literal |
| concurrency | semaphore is **per-execution**, not global | `executionSemaphores = new WeakMap()` and `getExecutionSemaphore` returning `new Sema(MAX_CONCURRENT_SUBAGENTS)` |
| nesting | depth limit = 5 | `MAX_SUB_EXECUTION_DEPTH` literal + the `currentDepth >= MAX_SUB_EXECUTION_DEPTH` gate + the error string |
| nesting | depth is carried, not gated elsewhere | `subExecutionDepth: currentDepth + 1` at the construction site; assert the *only* depth comparison is the session-recap one |
| workflow | the gate is one pure function with a persisted fallback | `resolveWorkflows` body verbatim |
| workflow | `session/new` cannot enable; `session/load` can | the two call sites — one with no second arg, one passing `persisted?.metadata.workflowsEnabled` |
| workflow | tool registration is all-or-nothing | the `validateWorkflowTool ? [...] : void 0` block naming all five tools |
| workflow | node/enum contract | `NodeTypeSchema`, `JoinPolicySchema`, `OnMaxIterationsSchema`, `WorkflowStatusSchema`, `MAX_REPEAT_ITERATIONS` |
| workflow | bundled recipe set | the `// src/bundled-workflows/*.workflow.json` markers (expect 7) |
| workflow | no env override exists | assert the `process.env.*` set contains no workflow key |
| hooks | canonical trigger set (11) | `TRIGGER_ALIAS_TABLE` keys + the alias mappings (`agentSpawn` -> `SessionStart`) |
| hooks | the subagent gate is `skipHooks` on exactly two nodes | `userHookOnPromptsNode2` + `agentStopHooksNode` early-returns |
| hooks | `dispatchKind` selects the adapter | `selectAdapter` body + both adapters' `buildDefinition` options |
| hooks | tool hooks are ungated | the `runPreToolUseHooks` / `executePostToolUseHooks` / `firePostFileHooks` call sites carry no guard |
| hooks | `sessionServices` passed to child by reference | the `sessionServices: state2.execution.sessionServices` line |
| hooks | stdin payload per trigger | `buildHookInput` switch arms |
| hooks | blocking/stdout decision table | `resolveHookOutput` body + `resolveStopContinueDecision` |
| hooks | load roots include home | `globalHookRoots` expression |
| hooks | symlinks are filtered out | `readDirectory`'s symlink branch **and** the loader's `type === "file"` filter (both halves — either alone is not the bug) |
| hooks | trust gates execution | `executionAllowed(v2) { return v2.workspaceTrusted; }` |
| hooks | loop guard exists | `skipHooksForNextToolCall` |
| agents | v3 profile schema | the `dispatchKind` enum + the `tools` tag vocabulary |
| limits | per-sub-execution turn bound | the ~300-turn guard in the sub-execution loop |
| limits | compaction scoping | the compaction trigger's session scoping (the Kiro#10482 site) |
| engine | no hook/workflow machinery in the Rust binaries | negative assertion: zero hits for the tool + hook names in both wrapped binaries |

**Positive controls are mandatory in every record.** "All absent" after a bundle
reshuffle looks identical to "all changed". So each record naming an absence must also
name strings **known present** at capture (e.g. `subagentOrchestration`, `toolSearch`)
— otherwise a future re-run reads as a clean confirmation of a bundle it can no longer
parse. Record *which* controls were used, not merely that controls existed.

## 4. Mode F — live fixtures, batched into minimum sessions

Each fixture: a scratch workspace, a stated setup, one prompt, and an assertion read
from the log or transcript. Grouped so one sitting settles many.

### Session A — workflow surface

1. **Enable path.** Seed `workflowsEnabled: true` into a persisted `session.json`
   under a scratch `KIRO_HOME`; resume it; run `bundled://ralph`.
   **Asserts:** the gate works, and the five tools register.
   **Negative control in the same session:** a *fresh* session (no seed) must not
   have them — proving the enable path is what did it.
2. **Custom agent in a step slot.** Does `step.agent` accept a user-authored agent,
   or only `wf-*`? Blocks the whole custom-workflow arm if it fails.
3. **`joinPolicy` semantics — all three values. The one live unknown that could
   simplify the design.** Mode E pins the *enum* (`all | allSettled | any`); this
   settles what each actually **does**, which the tool description never states.

   Setup: one `parallel` node, three branches with staggered sleeps (fast / medium /
   slow), each branch writing a start and end marker to its own file so completion is
   observable independently of what the workflow reports.

   | Value | What to assert | Why it matters |
   | --- | --- | --- |
   | `all` | node completes only after the slow branch; all three end markers present | the drain design's assumed baseline (§4.1) — if this is wrong the whole shape is wrong |
   | `allSettled` | completes after all three **even if one fails**; a failing branch does not abort siblings | decides whether a poisoned item can take down a whole branch set |
   | `any` | **the actual question:** after the fast branch completes, does the slow branch's END marker ever appear? | present ⇒ siblings are **orphaned** (they keep running); absent ⇒ **cancelled** |

   **Decision consequence, stated in advance so the result is actionable:** if `any`
   *cancels*, then first-completion resume destroys in-flight work and the
   self-draining-branch shape (§4.1) is the only correct drain — the avoidance was
   right. If `any` *orphans*, a root-driven drain becomes available: root resumes on
   first completion while the rest keep working, which is strictly closer to
   ultracode's `pipeline()` and removes the need for K pre-sized branches.

   Also record whether an orphaned branch's eventual completion is *reported* to the
   parent at all, or silently dropped — an orphan whose result is lost is not usable
   as a drain even though it keeps running.
4. **`repeat` + `fileCheck` drain**, K self-draining branches over the synthetic
   queue. The design's core claim.
5. **`send_message` mid-flight.** A step messages `'parent'` while a sibling is still
   running; assert arrival before the sibling returns.
6. **`inspect_workflow`** while running — does it show live per-node status?

### Session B — subagent + hook mechanics

7. **Nesting proof at depth.** Reuse the existing nonce methodology (parent mints a
   runtime nonce root never sees, child echoes it). Extend to **depth 3+**, and
   count concurrent `sub_agent_start` rows per `parentExecutionId` to read effective
   per-level concurrency.
   **Negative in the same fixture:** a **default-role** subagent must report the
   delegation tool ABSENT — that is the real content of "subagents cannot recurse".
8. **Depth-limit rejection.** Drive to depth 6; assert the
   `Sub-agent nesting depth limit (5) exceeded` error.
9. **Hook per-trigger split.** Two agent profiles differing in exactly one
   front-matter line (`dispatchKind: custom-agent` vs unset), a probe hook on all
   five triggers, and a unique marker in each agent's tool call.
   **Asserts:** tool hooks fire in both; prompt/stop hooks fire only in the
   `custom-agent` one; a second `SessionStart` appears only there.
10. **Hook payload + decision table.** From the same log: `UserPromptSubmit` carries
    `prompt: ""`; `PreToolUse` carries real `tool_input`; `PreToolUse` exit 0 stdout
    is discarded while exit 2 blocks; `PostToolUse` never injects.
11. **`Stop` exit 1 continuation.** Assert the turn restarts with the hook's text
    injected — the loop primitive.
12. **Hook load roots + the symlink trap.** Four cells: workspace/global x
    real-file/symlink. Asserts global loads, `KIRO_HOME` does **not** cover `hooks/`,
    and a symlinked hook is skipped **with no warning**.
13. **Agent-definition reload.** Edit a profile mid-session, resume, and assert the
    change does **not** take effect — restart required.

### Session C — limits

14. **MCP in subagents.** One worker declaring a server, one declaring none while
    root holds one; ask each to list tools; `ps` before/after. Settles the standing
    three-way contradiction, and it is the one limit question no code read resolved.

**The compaction tombstone is deliberately NOT a fixture.** Reproducing it means
driving a sub-execution past 80% context and destroying a parent session's stored
history — a destructive test for a finding already carried by a code read plus an
upstream issue with patches attached. Demoted to **mode R**: one record for the
compaction trigger's session scoping (§3) and one for the issue lookup (§4a). This is
exactly the trade the operator's "replayable evidence is acceptable" note licenses.

## 4a. Mode R (part 2) — machine-state measurement records

Each is one command plus its expected output, committed as
`fixtures/kiro-primitives/evidence/<name>.md`. Re-running one either reproduces the
recorded result or names what changed.

| Record | Command shape | Expected at capture |
| --- | --- | --- |
| Hooks do not fire in default-dispatch sub-executions | count hook-invocation rows in root transcripts vs `sub-executions/*.jsonl` | **437** across 49/185 root files vs **0** across 605 sub-execution files |
| …and that absence is not a recording gap | count `tool_call` rows in the same sub-execution files | 10,871 — the event family is recorded there |
| Global hooks do load | grep a transcript for a hook id under `$HOME` | a `…/.kiro/hooks/*.json#hook-N` id, status `completed`, in a project session |
| Workflow flag distribution | count `workflowsEnabled` across all `session.json` | 205 files: 11 `false`, 194 absent, **0 true** |
| No env override for workflows | enumerate `process.env.*` in the bundle | 13 `KIRO_*` vars, none workflow-related |
| Rust binaries carry no hook/workflow machinery | `strings … \| grep -c` for the tool and hook names | 0 for each — **with positive controls** (`subagentOrchestration`, `toolSearch`) non-zero |
| Nested sub-executions have occurred here | count sub-execution transcripts with a parent reference | 19 nested L2 transcripts |
| Upstream issue statuses | one issue query per id | the compaction, MCP-in-subagent, process-leak, headless-hang, and nesting issues with state + one-line claim |
| Reference repo's duplication | `md5sum` over its starter skill files | 33 files in **6 groups of 3** (22 redundant byte-identical copies) |

Two rules for this mode, both learned the hard way this session:

- **Every negative assertion ships a positive control.** "Zero hits" and "the file
  moved and I can no longer read it" are indistinguishable otherwise, and a control
  is the only thing that separates them. Record *which* controls were asserted.
- **A count is only meaningful with its denominator.** "0 hook rows in
  sub-executions" means nothing without "and 10,871 tool-call rows are there", which
  is what makes absence evidence.

## 5. Mode C — carried negatives and rejected designs

Recorded, **not executed**. These are the traps and the confounders; each gets a
short entry stating the belief, the reality, and how the mistake presented.

| Carried item | Why it earns its place |
| --- | --- |
| **`KIRO_HOME` does not cover `hooks/`** | actively confounded an earlier probe — a real global hook file "failed to load" for this reason alone |
| **Symlinked hook files are silently skipped** | the *other* half of that same confound; no warning is logged, so it presents as "global hooks don't work" |
| Those two combined produced a **wrong conclusion** that survived a re-confirmation | the highest-value entry in the whole layer: two independent causes, one symptom, and a probe that "confirmed" the wrong inference |
| **`onMaxIterations: "pause"` is a trap** | resume grants no further iterations, and a paused run cannot be retried — a rejected design, not a tuning choice |
| **A v2-shaped agent config is silently ignored under v3** | keys are no longer understood; presents as an agent that does nothing |
| **The TUI collapses subagent nodes** to `Orchestrated (N agents)` counting only direct children | a grandchild reads as root-spawned; the display lies, the transcripts do not |
| **"Subagents cannot recurse"** | true of the *default role* (no `subagent` tool), false of the engine (depth 5) — a role fact mistaken for a platform fact |
| **Docs say 4 concurrent subagents** | that is the v2 Rust limit; v3 is 5, and per-execution |
| **`stopCondition.completionSignal`** | in the schema, absent from the docs — do not rely on it |
| **Headless approval** | docs claim fail-fast; reports say indefinite hang; the child is spawned with null stdin, making an answer structurally impossible |
| **Long-lived drainer workers** | a working-looking design rejected on the compaction tombstone — worth carrying precisely because it *looks* right |
| **No level discriminator in the hook payload** | scope by profile, not by branching in the script — saves the next person writing an impossible hook |

## 6. Task order — Phase 1

| # | Task | Verified by |
| --- | --- | --- |
| T1 | Scratch harness: workspace + `KIRO_HOME` seeding, session synthesis, teardown | seeded session resumes; nothing outside the scratch dir is touched |
| T2 | **Mode R part 1** — code-read records (§3), semantic anchor first | each re-runs to its recorded result on the installed KAS; every absence carries named positive controls |
| T2b | **Mode R part 2** — machine-state records (§4a) | same bar; every count carries its denominator |
| T3 | Synthetic queue: two duration profiles, late-proposers, known answers | `queue_status --tree` renders the seeded lineage |
| T4 | Queue scripts — atomic claim (`O_EXCL` + lease TTL), push computing lineage depth and rejecting over-cap, status | concurrent-claim test: N claimers, zero double-claims |
| T5 | Workflow definitions: the drain, plus one per Session-A fixture | `validate_workflow` accepts them once the flag is on |
| T6 | Agent profiles: drainer, plus the `dispatchKind` pair and the nonce probes | present and loadable |
| T7 | Hook probe set + the 4-cell load-root matrix | log shape as specified |
| T8 | `EXPECT.md` predicates + `verify.py`, including call-graph reconstruction from transcripts | cross-check: lineage forest vs reconstructed graph agree |
| T9 | Runbook per session, spoon-fed step by step | operator can run a session without re-reading this plan |
| T10 | **Mode C** carried-negatives doc | each entry states belief / reality / how it presented |

T2 and T2b are independent of everything else and deliver value alone — it can land first
and start protecting the corpus before any live fixture exists.

## 6a. Phase 2 — in scope for this plan, sequenced after the original goal

**These are plan scope, not a maybe-pile.** They are deferred by *sequence*, not by
priority: the original goal gets settled first, then this phase runs. Operator:
*"to be clear inscope of plan, not in scope of this session … once we've settled the
original goal, we will circle back on those."*

**Do not investigate them during Phase 1** — the risk they were banked against is
losing them, not deferring them.

**The gate between phases, stated concretely so "settled" is testable.** Phase 1 is
done when both hold:

1. **The drain mechanic is settled either way** — the native workflow arm (§6.4 of the
   design doc) is proven on both duration profiles against the correctness predicate,
   *or* it is rejected on evidence and the dispatcher-tier fallback is proven instead.
   A rejection is a settlement; an unresolved arm is not.
2. **The Phase 1 records have landed** — mode R parts 1 and 2 (T2/T2b), and the
   mode-C carried negatives (T10).

Phase 2 then adds each item below to the fixture set on the same terms as everything
else: cheapest mode that can hold it (§2), general and free of private
references (§7), and every command actually run.

Each item carries the pointer already in hand, so the session that picks this up starts
warm instead of re-deriving where to look.

### F1 — Other builtin loop surfaces, starting with `/goal`

`/goal` should join the fixture set and be tested for full mechanics the way the
workflow surface was.

**Pointer already in hand:** the slash-command registration site that gates the
workflow command has a **sibling goal registration right beside it**, gated on a
*different* setting — a `goal` key rather than `workflows`, read from client settings
by a generic "is this setting enabled" helper rather than through the
persisted-fallback resolver. So `/goal`'s enable path may be **completely different
from the workflow one**, and possibly easier or harder. Do not assume it inherits the
seed-and-resume trick.

Second pointer: one of the seven bundled recipes is a **goal recipe**. So the open
question is whether `/goal` is a thin wrapper over that recipe or an independent
engine — which decides whether it is a new mechanic or a known one with a new door.

### F2 — Enumerate every slash-command source, do not guess

Rather than asking "is there a dedicated `/loop`?", **enumerate the command-source
registrations** in the bundle and record the full set with each one's gating
condition. Guessing at names finds only what you already suspected; the registration
list is the authoritative surface. Expect at least the workflow and goal sources; the
rest is the finding.

### F3 — Nesting mechanics inside and around workflows

Distinct from subagent nesting (already recorded). Open:

- Can a **workflow step** spawn subagents — i.e. does a step's session hold the
  delegation tool, and does `dispatchKind` apply to it?
- Can a workflow **run a workflow** (a step invoking `run_workflow`)? If so, is it
  bounded by the same depth counter as sub-executions, by a separate workflow-depth
  bound, or unbounded?
- Do **node types nest arbitrarily** — `repeat` inside `parallel` inside `repeat`? The
  schema is recursive on its face, but the runtime bound is the question.

### F4 — Inner-loop effects on the outer loop

The one the operator flagged directly: *does an inner loop impact the outer
loop/workflow?* Specific sub-questions worth splitting:

- Does an inner `repeat` exhausting `maxIterations` pause **the whole run** or only
  its own node? (The `pause` semantics already recorded make this sharp: a paused run
  cannot be retried, so the blast radius matters a lot.)
- Does a failing step propagate differently under `joinPolicy: all` versus
  `allSettled` versus `any`?
- Does an abort/cancel at one level propagate down, up, or neither?
- What does `update_workflow` with replace-remaining do to an **in-flight** inner
  node?

### F5 — Map the workflow parent hierarchy

`send_message` resolves a *workflow parent* and fails with "caller is not part of a
workflow or workflow has no parent" — which implies a hierarchy richer than
root/child. Map who can message whom across levels, and whether a grandchild can
reach the root or only its immediate parent.

### F6 — The other six bundled recipes as cheap coverage

Beyond the iterative-loop recipe already recorded, six more ship. Each exercises the
node types differently, so running them is unusually cheap breadth: no authoring
required, and any recipe that fails to validate or run is itself a finding about the
shipped surface.

### F7 — Task mechanics: are tasks immutable?

Logged, not investigated. The question as put: **task mechanics — immutable?**

Why it is worth its own item rather than folding into the queue work: if the engine
has a native task construct and its entries cannot be mutated after creation, that
is a hard constraint on any queue built on top of it — an item's state could only
advance by appending or by replacing the whole record, which changes the claim and
lease design (§10.1 L1/L7 of the design doc). If tasks _are_ mutable, a native task
store might substitute for the file queue entirely.

Scope it to: what the construct is, who may create one, whether an existing entry
can be edited or only appended to/replaced, whether state transitions are
constrained, and whether it is per-session or durable across sessions.

### F8 — Model and effort as independent knobs, at four levels

Logged, not investigated. The question as put: **model and effort control
(independent knobs)** at — skill, agent, launching a subagent, and an inline turn
if possible.

Two axes, and the second is the one that actually decides the design.

**Axis 1 — independence.** Whether effort can be set without also pinning the
model, and vice versa. If the two are welded together, "cheap worker under an
expensive orchestrator" may not be expressible at all.

**Axis 2 — PRECEDENCE.** Operator's framing: _a named agent defines model/effort;
when that agent is launched as a subagent, can the launcher override it?_ Resolve
the full lattice, because "can be set at level X" says nothing about who wins:

| Question | Why it matters |
| --- | --- |
| Does a launcher's per-dispatch value **override** the target agent's own declared value, or is it **ignored**? | decides whether one lean agent can be reused at several cost points, or whether each cost point needs its own near-duplicate agent profile |
| Is the direction **override**, **inherit-only**, or **floor/ceiling** (e.g. a child may go cheaper but not more expensive)? | a floor/ceiling rule is a real cost-safety mechanism and would be worth relying on; a silent ignore is a trap |
| Does an omitted field mean **inherit from the parent** or **fall back to the session/global default**? | those differ the moment a parent is itself non-default, and the difference is invisible until it bites |
| Is precedence the same for `model` and for `effort`, or do they resolve differently? | asymmetry here would be genuinely surprising and worth recording loudly |
| Does the resolved value appear anywhere observable (transcript row, usage record), or must it be inferred? | if it is not observable, none of the above can be verified empirically and the answer has to come from the bundle |

That last row is the practical gate: **settle observability first**, or every other
answer is unfalsifiable.

**SCOPE THIS DOWN — the Claude precedence chain is already settled.** It was
diagnosed separately on 2026-06-01, by deminifying the resolver in Claude binary
2.1.159. That diagnosis establishes, for Claude:

- **Precedence:** `CLAUDE_CODE_EFFORT_LEVEL` env var **beats everything** —
  launch-pin, configured `effortLevel`, and model default — with a two-tier
  **capability clamp** above it (`max` -> `high` and `xhigh` -> `high` when the model
  lacks the level).
- **Launch-pin is model-scoped**, firing only for specific opus model ids, so the env
  var is treadmill-proof.
- **The env var is a hard lock:** `/effort` is disabled while it is set.
- **`max` is session-only** — a separate array, not in the persisted
  `low|medium|high|xhigh` enum.
- **Kiro model lists are backend-driven** (an AWS list-models call), so model-enum
  extraction is infeasible for Kiro — do not budget time for it.

So F8's remaining surface is: **the Kiro side of precedence**, and the
**per-skill / per-agent / per-subagent-launch** levels on both harnesses. Do not
re-derive the Claude chain.

#### Settling observability — try these in cost order

The gate above asks whether a resolved model/effort value is observable at all. Three
paths, cheapest first. **Do not start at the bottom.**

**1. The engine's own request dump (try this first).** KAS's environment surface —
enumerated in `records/workflow-surface.md` while proving no workflow env override
exists — includes **`KIRO_DUMP_REQUESTS`** and **`KIRO_DUMP_REQUESTS_DIR`**, plus
`KIRO_CHAT_LOG_FILE` and `KIRO_LOG_LEVEL`. If the first pair does what its name
suggests, the engine will write out its own outbound requests and the whole question
is answered with an env var and no interception. This was found incidentally and
never followed up. **Start here.**

**2. The transcripts.** Check whether a per-turn `usage_summary`-style row already
records the model and effort actually used. If it does, precedence is observable
retroactively across every session already on disk — a far larger sample than any
live probe.

**3. TLS keylog + wire capture (operator's side idea; genuine last resort).** Export
a TLS key log from the client, capture the socket, and decrypt to read the request
bodies. This is the only path that yields true ground truth: not what the config
said, not what a log claimed, but what the field on the wire actually was — which is
exactly what distinguishes "the launcher's value overrode the agent's" from "it was
silently ignored".

Two practical wrinkles before budgeting time for it:

- **Runtime support differs per client.** Kiro's engine is Node, which has a
  first-class TLS keylog facility, so it is the likely candidate. Claude Code ships
  as a Bun single-executable, and whether it honours the same keylog convention is
  unverified — check before assuming symmetry between the two harnesses.
- **A capture is not a shareable artifact.** It contains auth tokens and complete
  prompt and response bodies. This corpus is destined to be **public**, and
  `records/`/`evidence/` are committed. So: capture outside the repo, never commit a
  `.pcap` or a key log, and if a finding comes out of one, record the **conclusion
  and the method**, never the capture. Treat a key log as a credential — it decrypts
  everything that session sent.

Given (1) exists and costs one env var, (3) should only be reached if the built-in
dump turns out to be absent, disabled, or lying.

Two warnings carried over from that diagnosis, which this item inherits:

- It is **version-scoped to 2.1.159** and its raw probe artifacts lived in `/tmp`, so
  they are gone. The findings survive; the artifacts do not.
- **Never anchor a grep on a minified identifier.** That diagnosis recorded the
  extractor breaking on a later release because a minifier-assigned variable name was
  regenerated. Anchor on stable source tokens. This is the same lesson the corpus
  learned independently about esbuild collision suffixes.

**Pointers already in hand, so this does not start cold:**

- **Per-dispatch: confirmed present.** The workflow `step` node carries **both**
  `modelId` and `effortLevel` as optional per-step fields — see the node contract
  in `records/workflow-surface.md`. So at least in the workflow surface the two are
  separately settable per dispatched step.
- **Per-session: fields exist.** A persisted `session.json` carries `modelId` and
  `effortLevel` as sibling top-level keys (visible in the key list recorded in the
  same records). Whether either is honoured on resume is untested.
- **Per-agent and per-skill: unknown.** The v3 agent-profile schema established in
  `records/hooks-dispatch-gate.md` covers `tools`, `permissions`, and
  `dispatchKind`; no model or effort field was observed, but absence was not
  asserted and no positive control was run for it. Treat as open, not as absent.
- **Inline turn: unknown**, and the most likely of the four to have no mechanism.

Note this item overlaps the Claude side, where effort pinning is already a typed
surface — so it is also the natural place to check whether the two harnesses can
share a cost-control contract or only a vocabulary.

## 6b. Unrelated follow-up owed — tracked here so it is not lost

**Not part of the corpus work.** Recorded in this plan only because it had no other
home and would otherwise survive solely as a memory entry, which makes it the most
forgettable item in flight.

**Make `hooks:isolate-config` idempotent against prek's installer.** The task
rewrites prek's generated `commit-msg` / `pre-commit` shims to prepend a
worktree-bootstrap guard. On a **second** `devenv shell` entry in the same
worktree, prek's installer sees a shim it does not recognize as its own, preserves
it as `commit-msg.legacy`, and installs a fresh one — and the mere existence of a
`.legacy` sibling puts the shim into "migration mode", which **fails every commit
in every worktree** (they share one `core.hooksPath`).

Encountered and worked around during this session by removing the stale duplicate
after verifying it was byte-identical to the live hook. The durable fix is either
to clear stale `*.legacy` siblings after rewriting, or to make the rewrite
something prek's installer recognizes.

**Do not** use prek's own suggested `prek install -f --hook-type commit-msg`: it
rewrites the shim from scratch and strips the bootstrap guard, so a
non-bootstrapped worktree would then silently skip every pre-commit check.

Own commit and own PR — it touches shared hook installation and wants its own
verification (fresh worktree, enter the shell twice, confirm a commit still
works). Full detail is recorded separately in the operator's notes.

## 7. Committed shape

Per the operator's constraint, the committed artifacts must be **general**. Nothing
here references any private repo: every mechanic came from the shipped binary or
from a public reference repo. The domain used by the drain fixture is **synthetic**
(sleep-and-report items with known answers), not a real review.

### 7.1 Both packaging questions are now settled

**Own self-contained directory — do NOT ride the half-built lab harness.** Operator
ruled. Home is:

```
fixtures/kiro-primitives/
├── records/<group>.md             # mode R part 1 — code-read invariants
├── evidence/<name>.md             # mode R part 2 — machine-state measurements
├── carried-negatives.md           # mode C
├── harness/                       # scratch workspace + KIRO_HOME seeding, teardown
├── workflows/*.workflow.json      # mode F definitions
├── agents/*.md                    # drainer + dispatchKind pair + nonce probes
├── hooks/*.json                   # probe set (REAL files — never symlinks)
├── queue/ + scripts/              # synthetic queue + claim/push/status
├── EXPECT.md + verify.py          # predicates + call-graph reconstruction
└── RUNBOOK-session-{a,b,c}.md     # spoon-fed operator steps
```

Rationale beyond the ruling: the lab harness's fake-user-global machinery targets a
*different tool's* global-config isolation and buys a Kiro fixture almost nothing,
since Kiro loads agents, hooks and steering workspace-locally. Riding an unmerged
6-commit branch would also couple this corpus's landing to that branch's completion.

**Isolation lever, chosen deliberately:** a scratch **workspace** is the primary
lever; `KIRO_HOME` is used only where a fixture specifically needs a synthesized
session (the workflow enable path). Note mode-F fixture 12 establishes that
`KIRO_HOME` **hides** global hooks rather than relocating them — so it is the wrong
default isolation lever, and any fixture that sets it must state whether it intends
global hooks to be invisible.

**No sidecar, no extractor, no nix wiring** — §2.1 withdrew that entirely. The
records are plain markdown beside the fixtures. Revisiting is a documented ritual, not
a job: re-run the records, and the recorded KAS version tells you at a glance whether
anything could have moved. §2.2 names the one condition under which automation becomes
warranted.

One hook-packaging invariant to carry into the build, because it is silent when
violated: **hook JSON must be delivered as real regular files.** A symlinked hook
file is skipped with no warning, which is half of what produced the wrong conclusion
recorded in mode C.
