# Records: concurrency and nesting (Kiro CLI v3)

Five replayable records covering the subagent concurrency limit, the shape of
the semaphore that enforces it, the nesting depth limit, how depth reaches a
child, and what the depth field is _not_ used for. All captured against KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29.

## How to replay these

Resolve the bundle first. Eight KAS versions were installed on the capture
machine; a glob that takes the first match silently picks a stale one, so the
resolver refuses on ambiguity rather than guessing.

```bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
ver=$(kiro-cli --version | awk '{print $NF}')                 # 2.15.1
matches=$(ls -d "$HOME/.local/share/kiro-cli/kas/${ver}-"*/ | wc -l)
[ "$matches" -eq 1 ] || { echo "AMBIGUOUS KAS - refuse"; exit 1; }
kas=$(ls -d "$HOME/.local/share/kiro-cli/kas/${ver}-"*/)
bundle="${kas}node_modules/@kiro/agent/dist/server/acp-server.js"
kasid=$(basename "${kas%/}")
```

At capture `$bundle` was **20752757** bytes. One record also reads the v2 Rust
chat binary as `$rustchat`; R-concurrency-1 records how that path was resolved.

Every command below was executed on 2026-07-29 in a `set -euETo pipefail` shell
in which `$bundle` (and `$rustchat`) already held the literal absolute paths.
Substituting those variable names for the literal paths is the only difference
between what is printed here and what was typed; every byte of every "output at
capture" block is real, unedited output of the command directly above it, with
`<<<` marking where a fixed-size window truncates.

Four conventions that matter for replay:

- **Never `cat` the bundle.** It is 20.8 MB. Read a window with
  `head -c $((OFFSET+N)) "$bundle" | tail -c M`. That form is preferred over
  `tail -c +OFFSET | head -c N`, because the latter gives `head` a reason to
  close the pipe early and, under `pipefail`, the resulting SIGPIPE on `tail`
  fails the whole command.
- **Count occurrences as `{ grep -boF X f || true; } | wc -l`, never
  `grep -c`.** `grep -c` counts matching _lines_, and the capture machine's
  `grep` is **ugrep 7.5.0**, where `-c -o` counts occurrences instead — so the
  two forms disagree (`subExecutionDepth`: 5 lines, 6 occurrences). The
  `-bo | wc -l` form is unambiguous on both, and the `|| true` keeps a
  legitimate zero from failing the pipeline.
- **Byte offsets in these records are conveniences, not anchors.** They move on
  every rebuild. The semantic anchor is the durable part.
- **The bundle is not identifier-minified.** Worth knowing before you start: it
  is esbuild-bundled but pretty-printed, keeps `// src/<path>.ts` section
  markers, and keeps original names and comments. What _does_ churn is esbuild's
  collision suffixes — `state2`, `graph2`, `cached4`, `resolve24` — so those
  specific handles remain untrustworthy across releases.

---

## R-concurrency-1 — Establish that the v3 concurrency limit is 5, and that the widely-quoted 4 is a different mechanism in a different engine

**Establishes:** under v3 the per-parent subagent concurrency limit is **5**
(`MAX_CONCURRENT_SUBAGENTS = 5` in the KAS bundle). The figure of **4** that
circulates for Kiro comes from the **v2 Rust** chat binary, where it is a
_rejection of an oversized batch_, not a queueing limit.

**Why it matters:** capacity arithmetic done with 4 is wrong by 25% per tier,
and it compounds — with the per-execution semaphore of R-concurrency-2, one
dispatcher tier is 5x5 = 25 rather than 4x4 = 16. The mechanism difference
matters more than the number: v2 **fails** an over-wide dispatch, v3 **queues**
the sixth. Code written against v2's semantics treats over-fanout as an error
path that under v3 never fires.

**Semantic anchor:** in the v3 engine, the invoke-subagent tool module opens
with two module-level integer constants side by side — a nesting depth ceiling
and a concurrency ceiling — and the concurrency one is the argument to the
semaphore constructor. Nothing else consumes it except the bundled
spec-task-execution steering, which quotes the number to the model in prose. In
the v2 Rust engine, the subagent tool's own source file instead carries a flat
human-readable rejection message about spawning more than four at once, sitting
next to an "Invoking N subagents in parallel" progress string — i.e. it
validates the batch size of a single tool call.

**Verified against:** KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29.

**Command:**

```bash
grep -boF 'MAX_CONCURRENT_SUBAGENTS' "$bundle"
head -c $((18013580+195)) "$bundle" | tail -c 252
```

**Output at capture:**

```
17062341:MAX_CONCURRENT_SUBAGENTS
17598176:MAX_CONCURRENT_SUBAGENTS
17598208:MAX_CONCURRENT_SUBAGENTS
18013613:MAX_CONCURRENT_SUBAGENTS
18013922:MAX_CONCURRENT_SUBAGENTS
```

```
// src/tools/invoke-subagent.ts
init_model_config();
var MAX_SUB_EXECUTION_DEPTH = 5;
var MAX_CONCURRENT_SUBAGENTS = 5;
var executionSemaphores = /* @__PURE__ */ new WeakMap();
var executionFileTreeCache = /* @__PURE__ */ new WeakMap();
function getExe<<<
```

All five hits are accounted for: one prose mention inside the bundled
spec-task-execution steering
(`Dispatch up to MAX_CONCURRENT_SUBAGENTS (5) ready tasks concurrently`, at
17062341), two in the module's re-export table, the declaration, and the single
real consumer — the `new Sema(...)` call of R-concurrency-2.

**Command** (the v2 contrast; the resolver is Nix-store-shaped because the
capture machine installs kiro-cli through Nix, and the `case` arm exists because
`bin/kiro-cli-chat` there is a 218-byte wrapper script, not the ELF):

```bash
launcher=$(readlink -f "$(command -v kiro-cli)")
pkg=$(grep -oE '/nix/store/[a-z0-9]{32}-kiro-cli-[^/]*' "$launcher" | head -1)
rustchat=$(readlink -f "$pkg/bin/kiro-cli-chat")
case "$(file -bL "$rustchat")" in
  *ELF*) ;;
  *) rustchat="$(dirname "$rustchat")/.$(basename "$rustchat")-wrapped" ;;
esac
rustchat=$(readlink -f "$rustchat")
echo "rustchat=$rustchat"
file -bL "$rustchat" | cut -c1-40

grep -aboF 'subagents at a time' "$rustchat"
head -c $((398689980+19)) "$rustchat" | tail -c 130 | tr -c '[:print:]\n' '.'
```

**Output at capture:**

```
rustchat=/nix/store/qh137p3awp4dr0am6w4i49xjlj0mrp29-kiro-cli-2.15.1/bin/.kiro-cli-chat-wrapped
ELF 64-bit LSB pie executable, x86-64, v
398689980:subagents at a time
ools/use_subagent.rsevent crates/chat-cli/src/cli/chat/tools/use_subagent.rs:364eYou can only spawn 4 or fewer subagents at a time
```

The `tr` is needed because these are Rust string-table bytes with no newlines;
`.` stands in for each non-printable byte. The neighbouring panic locations name
`crates/chat-cli/src/cli/chat/tools/use_subagent.rs`, which is v2's subagent
tool — a different tool from v3's `invoke_sub_agent`.

**Positive controls:** this record asserts that the v2 string is absent from the
v3 bundle **and** that the v3 constant is absent from the v2 binary, so both
directions need controls.

```bash
occ() { { grep -aboF "$1" "$2" || true; } | wc -l; }
for s in 'or fewer subagents at a time' 'MAX_CONCURRENT_SUBAGENTS' \
         'invoke_sub_agent' 'getExecutionSemaphore'; do
  printf 'bundle   %-30s %s\n' "$s" "$(occ "$s" "$bundle")"
done
for s in 'MAX_SUB_EXECUTION_DEPTH' 'nesting depth limit' \
         'use_subagent.rs' 'invoke_sub_agent'; do
  printf 'rustchat %-30s %s\n' "$s" "$(occ "$s" "$rustchat")"
done
```

```
bundle   or fewer subagents at a time   0
bundle   MAX_CONCURRENT_SUBAGENTS       5
bundle   invoke_sub_agent               31
bundle   getExecutionSemaphore          4
rustchat MAX_SUB_EXECUTION_DEPTH        0
rustchat nesting depth limit            0
rustchat use_subagent.rs                6
rustchat invoke_sub_agent               5
```

So each zero sits beside a non-zero control read from the same file by the same
method: a future re-run that reports every row as 0 has lost its grip on the
files, not discovered a removal.

**Notes:** the v2 chat binary is ~555 MB and **embeds minified JS alongside the
Rust code** — the five `invoke_sub_agent` hits in it live in that embedded JS
region (~394–397 MB), while the `use_subagent.rs` strings are Rust panic
locations near 398.7 MB. Classify any hit in that binary by its neighborhood
before drawing a conclusion from it. Vendor documentation stating "up to four
subagents at once" was **not** checked by command here; it is recorded only as
the likely origin of the 4. This record goes stale if either constant's literal
changes, or if v2's batch validator is replaced by a semaphore.

---

## R-concurrency-2 — Establish that the concurrency semaphore is per-execution, so a dispatcher tier multiplies capacity

**Establishes:** permits are not drawn from one process-wide pool. A `WeakMap`
keyed on the **parent execution object** lazily mints a fresh
`Sema(MAX_CONCURRENT_SUBAGENTS)` per execution, so every parent — including a
subagent that itself dispatches — gets its own 5 permits.

**Why it matters:** this inverts the arithmetic of a dispatcher tier. Under a
global pool, inserting a middle tier _spends_ capacity: the dispatchers occupy
slots the workers would have used. Per-execution, the tier _multiplies_ — root's
5 permits hold 5 dispatchers, each holding 5 workers, for 25 concurrent leaves.
A wave-free drain then becomes a question of who refills a freed slot rather
than of how few slots exist.

**Semantic anchor:** immediately after the two ceiling constants, the
invoke-subagent module declares two `WeakMap`s used as per-execution lazy caches
— one for the semaphore, one for a file-tree context. The semaphore getter takes
an `execution`, looks it up, and on a miss constructs a counting semaphore sized
by the concurrency constant and stores it under that execution. The tool's
handler calls that getter with **its own execution** (the dispatching parent),
awaits an abort-aware acquire, and releases in a `finally`. The permit's scope
is therefore exactly the lifetime of one parent execution object, and a child
execution is a _different_ object with its own future map entry.

**Verified against:** KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29.

**Command:**

```bash
grep -boF 'executionSemaphores' "$bundle"
head -c $((18013769+262)) "$bundle" | tail -c 271
grep -boE 'getExecutionSemaphore\([^)]*\)' "$bundle"
grep -boE 'acquireWithAbort\([^)]*\)' "$bundle"
```

**Output at capture:**

```
18013647:executionSemaphores
18013822:executionSemaphores
18013953:executionSemaphores
```

```
function getExecutionSemaphore(execution) {
  let semaphore = executionSemaphores.get(execution);
  if (!semaphore) {
    semaphore = new import_async_sema2.Sema(MAX_CONCURRENT_SUBAGENTS);
    executionSemaphores.set(execution, semaphore);
  }
  return semaphore;
}
async<<<
```

```
18013769:getExecutionSemaphore(execution)
18025348:getExecutionSemaphore(state2.execution)
18014314:acquireWithAbort(semaphore, signal2)
18025399:acquireWithAbort(semaphore, state2.execution.abortController.signal)
```

There is exactly **one** production call site,
`getExecutionSemaphore(state2.execution)`; the other offset is the definition's
own parameter list. So no global fallback pool exists to be reached by some
other path.

**Command** (acquire and release semantics — the reason 6 queues rather than
errors):

```bash
head -c $((18014314+645)) "$bundle" | tail -c 660
head -c $((18045176+20)) "$bundle" | tail -c 60
```

**Output at capture:**

```
async function acquireWithAbort(semaphore, signal2) {
  if (signal2?.aborted) {
    throw new Error("Aborted before semaphore acquire");
  }
  if (!signal2) {
    await semaphore.acquire();
    return;
  }
  return new Promise((resolve24, reject) => {
    let settled = false;
    const onAbort = () => {
      if (!settled) {
        settled = true;
        reject(new Error("Aborted while waiting for concurrency semaphore"));
      }
    };
    signal2.addEventListener("abort", onAbort, { once: true });
    void semaphore.acquire().then(() => {
      signal2.removeEventListener("abort", onAbort);
      if (!settled) {
        settled = true;
        res<<<
```

```
ge.state
      };
    } finally {
      semaphore.release();<<<
```

**Positive controls:** not required — this record asserts a presence, not an
absence.

**Notes:** two consequences follow from `acquireWithAbort` rather than from the
map. First, exceeding 5 **queues**: the sixth dispatch awaits a permit and
proceeds when one frees, and the only errors on this path are abort races
(`Aborted before semaphore acquire`,
`Aborted while waiting for concurrency semaphore`). Second, `WeakMap` keying
means permits are reclaimed with the execution object, so nothing accumulates
across runs. This record goes stale if the map is replaced by a module-level
`Sema`, if the call site is passed something other than the dispatching
execution, or if a second production call site appears.

---

## R-nesting-1 — Establish the nesting depth limit of 5, its gate, and its exact error text

**Establishes:** sub-agent nesting is capped at **5**
(`MAX_SUB_EXECUTION_DEPTH = 5`). The gate compares the _current_ execution's
depth against the ceiling **before** dispatching, as
`if (currentDepth >= MAX_SUB_EXECUTION_DEPTH)`, and rejects with
`Sub-agent nesting depth limit (5) exceeded`.

**Why it matters:** nesting works, and there is a budget to spend deliberately —
a root/dispatcher/worker arrangement costs 2 of the 5 levels, leaving 3 for a
worker's own helpers. The `>=`-before-increment form also fixes where the
boundary is: an execution already at depth 5 cannot dispatch, so the deepest
reachable execution is at depth 5 with root at 0 — six levels of execution, five
levels of nesting.

**Why the exact wording matters:** the rejection is **not thrown**. It is
emitted as an `Error`-state action and returned as a _synthetic tool message_
with an empty response, so the parent model sees a failed tool call and keeps
going. Code that expects an exception, or that reads an empty response as "no
work found", will misinterpret a depth rejection.

**Semantic anchor:** at the top of the invoke-subagent tool's handler, after
registering the tool dispatch and destructuring the input (subagent name,
prompt, explanation, preset, context files, inline agent, pre-generated
execution id), the handler reads the depth off its own execution into a local,
compares that local against the module's depth constant with `>=`, and on
failure builds a template-literal message interpolating the constant, logs a
warning tagged with the subagent graph, emits an `Error`-state
`invoke_sub_agent` action, and returns an empty response plus a synced tool
message. The constant is declared adjacent to the concurrency constant
(R-concurrency-1).

**Verified against:** KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29.

**Command:**

```bash
grep -boF 'MAX_SUB_EXECUTION_DEPTH' "$bundle"
grep -boF 'nesting depth limit' "$bundle"
head -c $((18020869+730)) "$bundle" | tail -c 736
```

**Output at capture:**

```
18013580:MAX_SUB_EXECUTION_DEPTH
18020944:MAX_SUB_EXECUTION_DEPTH
18021033:MAX_SUB_EXECUTION_DEPTH
18021010:nesting depth limit
```

```
const currentDepth = state2.execution.subExecutionDepth;
    if (currentDepth >= MAX_SUB_EXECUTION_DEPTH) {
      const errorMessage2 = `Sub-agent nesting depth limit (${MAX_SUB_EXECUTION_DEPTH}) exceeded`;
      logger.warn(`[SubAgentGraph] ${errorMessage2}, rejecting invocation of ${subagentId}`);
      this.emitAction(state2, {
        actionId: operationId,
        actionState: "Error" /* Error */,
        actionType: "invoke_sub_agent",
        input: { prompt, explanation, subAgentName: subagentId, contextFiles },
        errorMessage: errorMessage2,
        rawInput: input
      });
      return {
        output: { response: "" },
        state: this.withSyncToolMessage(state2, toolUse, errorMessage2, false).state
     <<<
```

All three constant hits are accounted for: the declaration (18013580), the gate
comparison (18020944), and the interpolation inside the message (18021033).

**Positive controls:** not required — this record asserts a presence, not an
absence.

**Notes:** the depth ceiling is an _engine_ limit, and it is not the reason an
out-of-the-box subagent fails to nest. The default subagent role ships without a
subagent-invocation tool, so it has no way to reach this gate at all; "subagents
cannot recurse" is a **role configuration** observation, not this constant.
Keeping the two apart is what makes a dispatcher tier possible. This record goes
stale if the literal changes, if `>=` becomes `>`, or if the rejection becomes a
thrown error rather than a returned tool message.

---

## R-nesting-2 — Establish that depth is carried into the child by the dispatch site, incremented once

**Establishes:** the child's depth is not derived, inherited implicitly, or
recomputed. The single sub-agent execution construction site passes
`subExecutionDepth: currentDepth + 1` explicitly, in the same object literal
that names the child's agent, and the receiving constructor defaults a missing
value to `0`.

**Why it matters:** depth is a plain constructor field on an in-process object.
That is what makes R-nesting-1's ceiling enforceable — and also why depth is
**invisible outside the process**. It is never placed in a hook payload, never
in the environment, never in the child's prompt. A design that wants a
level-aware child must carry its own depth marker (in the dispatch text, or in
on-disk state); it cannot read this one. The `?? 0` default is the other half:
an execution constructed without the field _is_ a root, so root-ness is the
absence of a value rather than a separate flag.

**Semantic anchor:** the invoke-subagent handler, having passed the depth gate,
constructs a new agent execution and populates it from the resolved sub-agent
definition — handler, execution id, chat session id, simulated turn message,
title — then three fields taken **from the parent's own execution by reference**
(session services, prompt context, abort signal), and finally the depth as the
parent's local depth plus one, together with the sub-agent's name. On the
receiving side the execution class documents the field as
`Nesting depth for sub-agent invocations. 0 = top-level execution.` and its
constructor assigns `config.subExecutionDepth ?? 0`.

**Verified against:** KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29.

**Command:**

```bash
grep -boE 'subAgentExecution = [^;]{0,60}' "$bundle"
head -c $((18038189+80)) "$bundle" | tail -c 330
head -c $((16939251+40)) "$bundle" | tail -c 200
head -c $((16944261+55)) "$bundle" | tail -c 60
```

**Output at capture:**

```
18033127:subAgentExecution = new AgentExecution({
```

```
hideSimulatedTurnMessage: subAgentDefinition.hideSimulatedTurnMessage,
        sessionServices: state2.execution.sessionServices,
        promptContext: state2.execution.promptContext,
        signal: state2.execution.abortController.signal,
        subExecutionDepth: currentDepth + 1,
        agentName: subagentId
      });
   <<<
```

```
ionId;
  simulatedTurnMessage;
  titlePrompt;
  title;
  hideSimulatedTurnMessage;
  /** Nesting depth for sub-agent invocations. 0 = top-level execution. */
  subExecutionDepth;
  /** Name of the sub<<<
```

```
this.subExecutionDepth = config2.subExecutionDepth ?? 0;
   <<<
```

**Positive controls:** not required — this record asserts a presence. The
related _absence_ claim, that nothing else reads this field, is R-nesting-3,
which carries the controls.

**Notes:** `new AgentExecution` appears once on the sub-agent path, so there is
one place depth can be set and one place it can skew. The neighbouring
`sessionServices` / `promptContext` / `signal` lines are worth remembering
independently: the child shares those objects **by reference** with its parent,
so a sub-execution is an in-process object rather than a separate process —
which is why dispatch churn costs no OS processes. This record goes stale if a
second sub-execution construction site appears (the increment could then
diverge), or if depth starts being threaded through the dispatch payload, which
would make it externally observable and change the design conclusion above.

---

## R-nesting-3 — Establish the negative: the only comparison on the depth field gates session recap, and nothing gates hooks or dispatch on depth

**Establishes:** across the whole 20.8 MB bundle the depth field occurs **6
times**, and exactly **one** of those is a comparison on the field itself —
`this.subExecutionDepth === 0 && isFeatureEnabled("sessionRecap")`, which
suppresses post-run recap generation for sub-executions. The only other depth
comparison anywhere is R-nesting-1's nesting gate, which compares a **local
alias** bound from the field one line earlier. Neither hooks, tool availability,
nor dispatch eligibility is gated on depth.

**Why it matters:** "am I a subagent?" is not a question the engine asks itself
in the places one would expect, so root/sub behavior differences must come from
somewhere else — and they do. The prompt-hook and agent-stop graph nodes
short-circuit on a **`skipHooks` boolean set by the dispatch adapter**, not on
depth. That moves the lever from a depth check you cannot influence to a profile
field you can, and it is why tool hooks — which touch neither gated node — are
not depth-gated at all. Reading this record wrongly, as "depth gates hooks", is
the mistake it exists to prevent.

**Semantic anchor:** search for the execution class's nesting-depth field. Every
occurrence should classify into exactly one of: the field declaration with its
`0 = top-level execution` doc comment; the constructor's `?? 0` default (two
occurrences on one line, LHS and RHS); the success path's recap guard, where
depth-zero plus a feature flag starts a background recap; the tool handler's
read into a local before the nesting gate; and the child construction site's
increment. Separately, search for the local alias the gate uses: outside the
invoke-subagent module its name collides with two unrelated vendored helpers — a
depth-limited JSON stringifier and Ramda's `uncurryN` — so classify by
neighborhood, never by name.

**Verified against:** KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29.

**Command:**

```bash
grep -boE 'subExecutionDepth[^;,)]{0,45}' "$bundle"
grep -boE 'currentDepth[^;,)]{0,40}' "$bundle"
head -c $((16955553+105)) "$bundle" | tail -c 175
```

**Output at capture:**

```
16939251:subExecutionDepth
16944261:subExecutionDepth = config2.subExecutionDepth ?? 0
16955553:subExecutionDepth === 0 && isFeatureEnabled("sessionRecap"
18020901:subExecutionDepth
18038189:subExecutionDepth: currentDepth + 1
```

```
4080184:currentDepth
4080291:currentDepth >= depthLimit
4080469:currentDepth + 1
4080585:currentDepth + 1
14446381:currentDepth = 1
14446479:currentDepth <= depth && typeof value === "function"
14446554:currentDepth === depth ? arguments.length : idx + va
14446717:currentDepth += 1
18020869:currentDepth = state2.execution.subExecutionDepth
18020928:currentDepth >= MAX_SUB_EXECUTION_DEPTH
18038208:currentDepth + 1
```

```
 },
      "success"
    );
    this.commitTermination();
    if (this.subExecutionDepth === 0 && isFeatureEnabled("sessionRecap")) {
      this.startRecap();
    }
    this.pr<<<
```

**Command** (the two hook nodes — confirm their guard is `skipHooks`, not
depth):

```bash
grep -boE 'execution\.skipHooks[^;{]{0,40}' "$bundle"
head -c $((17166396+115)) "$bundle" | tail -c 130
head -c $((14071561+110)) "$bundle" | tail -c 125
```

**Output at capture:**

```
14071603:execution.skipHooks)
14514598:execution.skipHooks)
17166441:execution.skipHooks)
18036143:execution.skipHooks. The default sub-agent adapter sets it
```

```
async function userHookOnPromptsNode(state2) {
  if (state2.execution.skipHooks) {
    return state2;
  }
  const input = state2.e<<<
```

```
async function agentStopHooksNode(state2) {
  if (state2.execution.skipHooks) {
    return state2;
  }
  if (!state2.onAgentS<<<
```

**Denominators, stated because a count without one means nothing:**

| Handle                             | Occurrences | Comparisons | Classification                                                                                                                                     |
| ---------------------------------- | ----------: | ----------: | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `subExecutionDepth`                |           6 |           1 | 1 field declaration; 2 constructor default (one line); **1 recap guard**; 1 read into the gate's local; 1 increment at the child construction site |
| `currentDepth`, invoke-subagent    |           3 |           1 | 1 bind from the field; **1 nesting gate**; 1 increment                                                                                             |
| `currentDepth`, unrelated vendored |           8 |           3 | 4 in a depth-limited JSON stringifier (offsets near 4.08 MB); 4 in Ramda `uncurryN` (near 14.45 MB) — neither touches sub-executions               |

So: **two depth comparisons in the engine, total.** One gates session recap; one
gates nesting. Zero gate hooks, tools, or dispatch.

**Positive controls:** the load-bearing claim here is an absence, so a future
re-run must be able to distinguish "the guards were removed" from "the bundle
moved and my grep no longer parses it".

```bash
occ() { { grep -boF "$1" "$bundle" || true; } | wc -l; }
for s in subExecutionDepth MAX_SUB_EXECUTION_DEPTH MAX_CONCURRENT_SUBAGENTS \
         skipHooks dispatchKind invoke_sub_agent getExecutionSemaphore \
         isSubExecution isRootSession isSubAgent subagentDepth nestingDepth \
         MAX_SUBAGENT_DEPTH executionDepth; do
  printf '%-26s %s\n' "$s" "$(occ "$s")"
done
```

```
subExecutionDepth          6
MAX_SUB_EXECUTION_DEPTH    3
MAX_CONCURRENT_SUBAGENTS   5
skipHooks                  29
dispatchKind               16
invoke_sub_agent           31
getExecutionSemaphore      4
isSubExecution             0
isRootSession              0
isSubAgent                 0
subagentDepth              0
nestingDepth               0
MAX_SUBAGENT_DEPTH         0
executionDepth             0
```

The first seven rows are the **controls**: names known present at capture. The
last seven are the **absences** — the identifiers a depth-or-identity guard
would plausibly have used, none of which exists. (`executionDepth` is 0 because
the real field is `subExecutionDepth`, with a capital `E`, so the lowercase
spelling is not a substring of it.) If a re-run reports the absence rows still 0
**and** the control rows near these values, the negative holds. If the control
rows collapse toward 0, the grep has stopped finding the code — the code has not
stopped existing.

**A correction this record makes.** The claim often stated as _"the only depth
comparison in the entire bundle gates session recap"_ is **not reproducible as
written**: it omits the nesting gate, which is also a depth comparison. The
reproducible form is the one above — the only comparison on the _field_ is the
recap guard; the only other depth comparison is the nesting gate, on a local
alias. Both halves are load-bearing, because dropping the first makes the recap
finding sound like the depth ceiling, and dropping the second makes the sentence
false.

**Notes:** `grep -boE 'subExecutionDepth[^;,)]{0,45}'` returns **5** rows where
the fixed-string search returns **6** occurrences — the regex swallows the
constructor's LHS and RHS in a single match. Use the fixed-string form for
counts and the regex form for classification. This record also covers only what
the _bundle_ does with depth; whether tool hooks in fact fire inside a live
sub-execution is a session-level question no static read can close. It goes
stale if a third engine depth comparison appears, if either hook node's guard
changes from `skipHooks` to something depth- or identity-derived, or if any of
the absent identity predicates starts returning hits.
