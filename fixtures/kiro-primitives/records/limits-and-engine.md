# Records: per-execution limits and the engine split (Kiro CLI v3)

Six replayable records covering what bounds a single sub-execution, what does
not, the compaction trigger and its session scoping, the process model of a
sub-execution, whether the Rust binaries carry any hook or workflow machinery,
and whether the settings surface exposes a per-subagent budget. All captured
against KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29. **Three records are negatives and carry positive
controls, and R-engine-1 records a claim these commands FAILED to reproduce.**

## How to replay these

Resolve the KAS bundle first. Several KAS versions were installed on the capture
machine, so the resolver refuses on ambiguity rather than globbing and taking
the first match.

```bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
ver=$(kiro-cli --version | awk '{print $NF}')                 # 2.15.1
shopt -s nullglob
kasdirs=( "$HOME/.local/share/kiro-cli/kas/${ver}-"*/ )
[ "${#kasdirs[@]}" -eq 1 ] || { echo "AMBIGUOUS KAS - refuse (found ${#kasdirs[@]})"; exit 1; }
kas="${kasdirs[0]}"
bundle="${kas}node_modules/@kiro/agent/dist/server/acp-server.js"
kasid=$(basename "${kas%/}")
```

At capture `$bundle` was **20752757** bytes and `$kasid` was the value above.
`ls -d "$HOME/.local/share/kiro-cli/kas/"*/ | wc -l` returned **7**, so seven
KAS trees were present. That count is incidental to every record here, but note
it if you are reconciling a resolver against an older transcript that says
eight.

Two records also read the wrapped Rust binaries. The capture machine installs
kiro-cli through Nix, so the resolver below is Nix-store-shaped; on a
conventional install, point the variables at the ELF binaries directly. Note the
package ships **three** ELF binaries — a launcher, the v2 chat engine, and a
terminal-integration helper — and that each `bin/` entry is a small shell
wrapper rather than the ELF, hence the `case` arm.

```bash
launcher=$(readlink -f "$(command -v kiro-cli)")
pkg=$(grep -oE '/nix/store/[a-z0-9]{32}-kiro-cli-[^/]*' "$launcher" | head -1)
elf() {
  p=$(readlink -f "$1")
  case "$(file -bL "$p")" in *ELF*) ;; *) p="$(dirname "$p")/.$(basename "$p")-wrapped" ;; esac
  readlink -f "$p"
}
rustmain=$(elf "$pkg/bin/kiro-cli")       # 53809000 bytes at capture
rustchat=$(elf "$pkg/bin/kiro-cli-chat")  # 555372744 bytes at capture
```

Every command below was executed on 2026-07-29 with `$bundle`, `$rustmain` and
`$rustchat` already holding the literal absolute paths. Substituting those
variable names for the literal paths is the only difference between what is
printed here and what was typed; every byte of every "output at capture" block
is real, unedited output of the command directly above it, with `<<<` marking
where a fixed-size window truncates.

Six conventions that matter for replay, four shared with the sibling
`concurrency-and-nesting.md` record and repeated because getting any of them
wrong silently changes the answer:

- **Never `cat` the bundle.** It is 20.8 MB. Read a window with
  `head -c $((OFFSET+N)) "$bundle" | tail -c M`. That form is preferred over
  `tail -c +OFFSET | head -c N`, because the latter gives `head` a reason to
  close the pipe early and, under `pipefail`, the resulting SIGPIPE on `tail`
  **can** fail the whole command.

  **Correction, 2026-07-30:** that SIGPIPE failure did **not** reproduce when
  re-tested — see the full note in `concurrency-and-nesting.md`, which is the
  authoritative record for it. Keep using `head … | tail …`, but treat the
  preference as a portability hedge rather than an observed failure here.

- **Count occurrences as `{ grep -boF X f || true; } | wc -l`, never
  `grep -c`.** `grep -c` counts matching _lines_, and the capture machine's
  `grep` is **ugrep 7.5.0**, where `-c -o` counts occurrences instead. Add `-a`
  when reading the Rust binaries, which are binary files.
- **Byte offsets in these records are conveniences, not anchors.** They move on
  every rebuild, so each window below is preceded by the `grep` that produced
  its offset. The semantic anchor is the durable part.
- **The KAS bundle is not identifier-minified.** It is esbuild-bundled but
  pretty-printed, keeps `// src/<path>.ts` section markers, and keeps original
  names and comments. What churns is esbuild's collision suffixes — `state2`,
  `graph3`, `Metrics14`, `graph5` — so those specific handles are untrustworthy
  across releases.
- **The 555 MB v2 chat binary embeds a whole JavaScript bundle alongside its
  Rust code.** On this build the Rust string tables sit below roughly 390 MB and
  the embedded JS above roughly 394 MB. **Classify every hit in that binary by
  its neighborhood before drawing a conclusion from it** — R-engine-1 exists
  partly because that step was skipped once.
- **Rust string tables have no separators**, so windows into them are piped
  through `tr -c '[:print:]\n' '.'` and every `.` stands for one non-printable
  byte. Adjacent words in those windows are adjacent _interned strings_, not
  source text.

---

## R-limits-1 — Establish the bound on a single sub-execution: 300 model-invoke entries, resettable, under a 6000-transition safety net

**Establishes:** a dispatched sub-agent runs as a custom-agent execution whose
graph state carries `agentIterationLimit = CUSTOM_AGENT_ITERATION_LIMIT = 300`.
The counter it is compared against increments **once per entry into the
model-invoke node** — i.e. per agent turn, not per model API call and not per
tool call. Above it sits a second, much larger ceiling: the graph runtime's
`recursionLimit`, set to
`CUSTOM_AGENT_GRAPH_TRANSITION_LIMIT = 4 * 300 * RECURSION_HEADROOM_FACTOR(5)` =
**6000** node transitions.

**Why it matters:** 300 turns is the only per-sub-execution work budget the
engine has, so any drain design that treats a worker as "bounded" is relying on
this number. But it is **not a hard 300 per execution**, and that is the part
worth carrying: a queued steering message both short-circuits the limit check
**and resets the counter to zero**. The real invariant is _300 consecutive
model-invoke entries with no queued message_, which is a weaker guarantee than
it first reads as. Termination has to come from the domain — a queue that runs
dry — not from this cap.

**Semantic anchor:** the shared graph-state annotation module declares two
numeric channels for this, with a doc comment that is the authoritative
statement: one channel counts entries into the model-invoke node and defaults to
0, the other holds the limit and deliberately has **no** default so an unset
limit surfaces as a programming error. A small `src/graphs/iteration-limit.ts`
module supplies three helpers — an incrementer returning a new state, a `>=`
predicate comparing count against limit, and a once-only warn-and-report — plus
two routers that consult them. Each agent flavour then supplies its own pair of
constants in its own definition module: a per-flavour iteration limit, and a
graph-transition limit derived from it by multiplying by a small per-flavour
fan-out factor and a shared headroom factor. The **dispatched sub-agent path
uses the custom-agent flavour**, whose `finalizeBuildState` returns the
iteration limit alongside the context and the chat session id, and whose
`invoke` passes the derived transition limit as the graph runtime's recursion
limit.

**Verified against:** KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29.

**Command** (every iteration and transition limit in the bundle, with its
defining expression — one command, so the denominator is visible):

```bash
grep -boE '[A-Z_]*(ITERATION|TRANSITION)_LIMIT[0-9]* = [0-9A-Za-z_.*() ]{1,70}' "$bundle"
grep -boE 'RECURSION_HEADROOM_FACTOR *=? *[0-9]*' "$bundle"
```

**Output at capture:**

```
14518975:CUSTOM_AGENT_ITERATION_LIMIT = 300
14519015:CUSTOM_AGENT_GRAPH_TRANSITION_LIMIT = 4 * CUSTOM_AGENT_ITERATION_LIMIT * RECURSION_HEADROOM_FACTOR
17029962:SPEC_ITERATION_LIMIT = 1e3
17029994:SPEC_GRAPH_TRANSITION_LIMIT = 5 * SPEC_ITERATION_LIMIT * RECURSION_HEADROOM_FACTOR
17232200:ITERATION_LIMIT = 300
17232227:GRAPH_TRANSITION_LIMIT = 8 * ITERATION_LIMIT * RECURSION_HEADROOM_FACTOR
17241069:EXECUTE_ITERATION_LIMIT = 300
17246502:PLAN_ITERATION_LIMIT = 300
17246534:GRAPH_TRANSITION_LIMIT2 = 8 * Math.max(PLAN_ITERATION_LIMIT
```

```
14073571:RECURSION_HEADROOM_FACTOR
14073844:RECURSION_HEADROOM_FACTOR = 5
14519088:RECURSION_HEADROOM_FACTOR
17030051:RECURSION_HEADROOM_FACTOR
17232274:RECURSION_HEADROOM_FACTOR
17246622:RECURSION_HEADROOM_FACTOR
```

So the denominator is **five iteration limits across four graph flavours**:
custom-agent 300 (the sub-agent path), chat 300, plan 300 and execute 300 (one
flavour, two limits), spec 1000 (`1e3`). Chat and custom-agent share the number
and differ in the fan-out factor (8 vs 4). The last row truncates because the
plan-execute expression wraps its two limits in `Math.max`, which the regex's
character class stops at.

**Command** (the semantics — the doc comment is the load-bearing part, because
it is what fixes the unit as agent turns rather than model calls):

```bash
grep -boF 'agentIterationNumber` counts' "$bundle"
head -c $((13664256+1150)) "$bundle" | tail -c 1300
```

**Output at capture:**

```
13664256:agentIterationNumber` counts
```

```
enFiles: Annotation(),
      activeFile: Annotation(),
      // Output that can be stored by nodes in the graph
      output: Annotation(),
      // `agentIterationNumber` counts MODEL_INVOKE node entries — i.e. agent
      // turns, NOT raw model API calls (one entry may issue several model calls,
      // e.g. context-overflow recovery does error+summary+retry under a single
      // entry). It is the user-facing cap on agent turns. `recursionLimit`
      // (passed to `graph.invoke()`) is a separate, much higher safety net for
      // routing bugs that don't invoke the model.
      //
      // `agentIterationNumber` defaults to 0 because graph `build()` functions
      // produce a SavedGraphState that does not set it — execution always begins
      // at turn 0. `agentIterationLimit` has NO default: every graph's initial
      // state (or the tool/spec Setup node) sets it explicitly, so an unset limit
      // is a programming error we want to surface, not silently treat as 0.
      agentIterationLimit: Annotation({ reducer: numericChannelReducer }),
      agentIterationNumber: Annotation({ reducer: numericChannelReducer, default: () => 0 }),
      // If there is an active stream going on, these types are used to handle it and route actions
      agentRawResponseMessage<<<
```

**Command** (who sets the limit — nine sites, all accounted for):

```bash
grep -boE 'agentIterationLimit: [A-Za-z_]+' "$bundle"
```

**Output at capture:**

```
13663339:agentIterationLimit: graph
13665114:agentIterationLimit: Annotation
14522979:agentIterationLimit: CUSTOM_AGENT_ITERATION_LIMIT
17027652:agentIterationLimit: iterationLimit
17155748:agentIterationLimit: SPEC_ITERATION_LIMIT
17159598:agentIterationLimit: SPEC_ITERATION_LIMIT
17238808:agentIterationLimit: ITERATION_LIMIT
17244750:agentIterationLimit: EXECUTE_ITERATION_LIMIT
17248927:agentIterationLimit: PLAN_ITERATION_LIMIT
```

Two are infrastructure — the state carry-over at 13663339 and the channel
declaration at 13665114 — one is the spec setup node taking a limit as a
parameter, and the remaining six are the per-flavour initial states. **The
sub-agent path is 14522979**, and it is the one that matters here.

**Command** (the enforcement, the custom-agent state that carries the limit, the
graph invoke that carries the safety net, and the two escapes):

```bash
grep -boF 'agentIterationLimit: CUSTOM_AGENT_ITERATION_LIMIT' "$bundle"
head -c $((14522979+200)) "$bundle" | tail -c 275
grep -boF '// src/graphs/iteration-limit.ts' "$bundle"
head -c $((14072282+560)) "$bundle" | tail -c 620
grep -boF 'function routeFinalResponse(state2, targets)' "$bundle"
head -c $((14073121+420)) "$bundle" | tail -c 500
grep -boF 'function consumeQueuedSteering(state2)' "$bundle"
head -c $((13826255+40)) "$bundle" | tail -c 350
head -c $((14523843+200)) "$bundle" | tail -c 215
```

**Output at capture:**

```
14522979:agentIterationLimit: CUSTOM_AGENT_ITERATION_LIMIT
```

```
ionId) {
        insertMsg0Separator(messages);
        return {
          agentIterationLimit: CUSTOM_AGENT_ITERATION_LIMIT,
          context: messages.reduce((ctx, message) => ctx.withNewMessage(message), ModelContext.empty()),
          chatSessionId,
          continuat<<<
```

```
14072240:// src/graphs/iteration-limit.ts
```

```
types();
  }
});

// src/graphs/iteration-limit.ts
function advanceIteration(state2) {
  return { ...state2, agentIterationNumber: state2.agentIterationNumber + 1 };
}
function hasReachedIterationLimit(state2) {
  return state2.agentIterationNumber >= state2.agentIterationLimit;
}
function reportIterationLimitReached(state2) {
  state2.execution.reportIterationLimitOnce(() => {
    logger.warn(
      `[IterationLimit] Reached iteration limit: ${state2.agentIterationNumber}/${state2.agentIterationLimit}. Stopping agent to prevent runaway execution.`
    );
    Metrics14.reportCountMetrics({ IterationLimitReached: <<<
```

```
14073051:function routeFinalResponse(state2, targets)
```

```
void 0;
}
function routeFinalResponse(state2, targets) {
  if (state2.execution.hasQueuedUserMessage()) {
    logger.info("[IterationLimit] Queued user message found - continuing");
    return targets.continueTarget;
  }
  const stop = iterationLimitTarget(state2, targets.terminationTarget);
  if (stop !== void 0) {
    return stop;
  }
  if (state2.contextOverflowRecovered) {
    logger.info("[IterationLimit] Context overflow recovered - continuing");
    return targets.continueTarget;
  }
  re<<<
```

```
13825883:function consumeQueuedSteering(state2)
```

```
 = state2.execution.consumeQueuedUserMessage();
  if (!queuedMessage) {
    return { state: state2, context: state2.context };
  }
  logger.info("Appending queued steering message to context");
  const newUserMessage = ContextChatMessage.fromHuman().withText(queuedMessage);
  return {
    state: { ...state2, agentIterationNumber: 0 },
    context: <<<
```

```

        await CustomAgentGraph.invoke(await execution.getState(), {
          recursionLimit: CUSTOM_AGENT_GRAPH_TRANSITION_LIMIT,
          signal: execution.abortController.signal
        });
        return {<<<
```

**Positive controls:** not required — this record asserts presences. The
companion _absence_ claim, that nothing else bounds a sub-execution, is
R-limits-2, which carries the controls.

**Notes.** Three consequences, in descending order of how likely they are to
bite a design:

1. **The reset is real and it is on the sub-execution's own path.** The node
   that consumes a queued steering message and zeroes the counter is called from
   `createModelInvokeNode`, the shared node the custom-agent graph installs as
   `MODEL_INVOKE`, so it is the same code in a sub-execution as in a root
   session. The queue slot is filled only by **live steering**, a user-driven
   mid-turn injection, so in practice a plain worker never receives one and 300
   holds — but nothing structural enforces that. Confirm the call site with
   `grep -boE 'consumeQueuedSteering\(' "$bundle"` (three hits: the definition,
   the shared model-invoke node, and the spec graph).
2. **`reportIterationLimitOnce` means the warn line appears once per
   execution**, not once per over-limit route. Do not count log lines to count
   executions that hit the cap.
3. **The routers stop by routing, not by throwing.** Hitting the cap routes to
   the flavour's termination target — for the sub-agent path, the agent-stop
   hooks node — so the parent sees a normal completion carrying whatever the
   worker had produced. There is no distinguishable "budget exhausted" result on
   the tool return.

This record goes stale if `CUSTOM_AGENT_ITERATION_LIMIT` changes, if the
dispatched-sub-agent path stops resolving to the custom-agent flavour, if `>=`
becomes `>`, or if the queued-message branch stops preceding the limit check.

---

## R-limits-2 — Establish the negative: nothing bounds a sub-execution by wall-clock, tool-call count, or token spend

**Establishes:** the iteration cap of R-limits-1 and the graph-transition
recursion limit are the **only** ceilings on a sub-execution. All four agent
graph entry points pass exactly two options to the graph runtime —
`{recursionLimit, signal}` — and the `signal` is an inherited **cancellation**
signal, not a deadline. The graph runtime does support a per-step timeout, and
it is never supplied on any agent path. No tool-call counter and no token budget
exist anywhere in the engine.

**Why it matters:** a worker cannot be given a deadline, a tool-call allowance,
or a token allowance by configuration, so a drain's cost control has to live
entirely in the domain — in what the worker is asked to do and in how few items
it is handed. It also means a stuck worker is stuck **until its parent aborts**:
the only thing that ends it early is the parent's abort signal propagating down,
which requires something outside the sub-execution to decide to abort.

**Semantic anchor:** each execution-definition class exposes an `invoke` method
whose whole body is one call into a compiled graph, awaiting
`Graph.invoke(await execution.getState(), { ... })` with an object literal
carrying the flavour's transition limit and the execution's abort signal, and
nothing else. Separately, the execution class's constructor takes an optional
parent signal and, when present, **registers an abort listener that aborts its
own controller**, so the child is cancellable from above but never
self-expiring. In the vendored graph runtime, the step loop reads a `timeout`
option and builds a timeout-based abort signal from it only when it is truthy;
since no agent call site supplies `timeout`, that construction never happens on
an agent path.

**Verified against:** KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29.

**Command** (all four graph entry points with their full option literals — the
denominator is 4 of 4):

```bash
grep -boE '[A-Za-z]+\.invoke\(await execution\.getState\(\)' "$bundle"
for o in 14523843 17160959 17240112 17249837; do
  echo "--- $o ---"; head -c $((o+200)) "$bundle" | tail -c 250
done
```

**Output at capture:**

```
14523843:CustomAgentGraph.invoke(await execution.getState()
17160959:SpecGenerationGraph.invoke(await execution.getState()
17240112:ChatAgentGraph.invoke(await execution.getState()
17249837:PlanExecuteGraph.invoke(await execution.getState()
```

```
--- 14523843 ---
  }
      async invoke(execution) {
        await CustomAgentGraph.invoke(await execution.getState(), {
          recursionLimit: CUSTOM_AGENT_GRAPH_TRANSITION_LIMIT,
          signal: execution.abortController.signal
        });
        return {<<<
--- 17160959 ---
 [msg];
  }
  async invoke(execution) {
    await SpecGenerationGraph.invoke(await execution.getState(), {
      recursionLimit: SPEC_GRAPH_TRANSITION_LIMIT,
      signal: execution.abortController.signal
    });
    return {
      status: "success" <<<
--- 17240112 ---
 [msg];
  }
  async invoke(execution) {
    await ChatAgentGraph.invoke(await execution.getState(), {
      recursionLimit: GRAPH_TRANSITION_LIMIT,
      signal: execution.abortController.signal
    });
    return {
      status: "success" /* Success<<<
--- 17249837 ---
    });
  }
  async invoke(execution) {
    await PlanExecuteGraph.invoke(await execution.getState(), {
      recursionLimit: GRAPH_TRANSITION_LIMIT2,
      signal: execution.abortController.signal
    });
    return {
      status: "success" /* Succ<<<
```

**Command** (the signal is inherited cancellation, not a deadline; and the
runtime's timeout facility exists but is unsupplied):

```bash
grep -boF 'this.subExecutionDepth = config2.subExecutionDepth ?? 0' "$bundle"
head -c $((16944256+405)) "$bundle" | tail -c 500
grep -boF 'AbortSignal.timeout' "$bundle" | awk -F: '$1>5000000'
head -c $((13516438+60)) "$bundle" | tail -c 260
```

**Output at capture:**

```
16944256:this.subExecutionDepth = config2.subExecutionDepth ?? 0
```

```
imulatedTurnMessage;
    this.hideSimulatedTurnMessage = config2.hideSimulatedTurnMessage;
    this.subExecutionDepth = config2.subExecutionDepth ?? 0;
    this.agentName = config2.agentName;
    this.titlePrompt = config2.titlePrompt;
    this.title = config2.title;
    if (config2.signal) {
      config2.signal.addEventListener("abort", () => {
        if (!this.isCompleted()) {
          this.abortController.abort();
        }
      });
    }
  }
  /**
   * Adds a new question that the execut<<<
```

```
5295228:AbortSignal.timeout
13516438:AbortSignal.timeout
```

```
      let graphBubbleUp;
        const exceptionSignalController = new AbortController();
        const exceptionSignal = exceptionSignalController.signal;
        const stepTimeoutSignal = timeout ? AbortSignal.timeout(timeout) : void 0;
        const pending<<<
```

That second offset is the graph runtime's step loop. Its `timeout` comes from
the options object the four call sites above build, and none of them sets it, so
`stepTimeoutSignal` is `void 0` on every agent step. The 69 total
`AbortSignal.timeout` occurrences are otherwise entirely in vendored SDK code
near 4 MB (67 of them) plus one HTTP helper at 5.3 MB — which is what the `awk`
filter above is for.

**Positive controls:** this record's load-bearing claim is an absence, so a
future re-run must be able to distinguish "the bounds were removed" from "the
bundle moved and my grep no longer parses it".

```bash
occ() { { grep -boF "$1" "$bundle" || true; } | wc -l; }
echo 'CONTROLS (expected non-zero)'
for s in agentIterationLimit agentIterationNumber CUSTOM_AGENT_ITERATION_LIMIT \
         RECURSION_HEADROOM_FACTOR hasReachedIterationLimit routeFinalResponse \
         recursionLimit AbortSignal.timeout maxConcurrency; do
  printf '  %-30s %s\n' "$s" "$(occ "$s")"; done
echo 'ABSENCES (expected zero)'
for s in maxTurns MAX_TURNS MAX_AGENT_TURNS turnTimeout TURN_TIMEOUT \
         maxToolCalls toolCallLimit MAX_TOOL_CALLS TOOL_CALL_LIMIT \
         TOKEN_BUDGET maxTokenBudget totalTokenLimit \
         wallClock wallClockLimit executionTimeout EXECUTION_TIMEOUT \
         subAgentTimeout subagentTimeout SUBAGENT_TIMEOUT agentTimeout AGENT_TIMEOUT; do
  printf '  %-30s %s\n' "$s" "$(occ "$s")"; done
```

```
CONTROLS (expected non-zero)
  agentIterationLimit            13
  agentIterationNumber           20
  CUSTOM_AGENT_ITERATION_LIMIT   4
  RECURSION_HEADROOM_FACTOR      6
  hasReachedIterationLimit       2
  routeFinalResponse             4
  recursionLimit                 48
  AbortSignal.timeout            69
  maxConcurrency                 51
ABSENCES (expected zero)
  maxTurns                       0
  MAX_TURNS                      0
  MAX_AGENT_TURNS                0
  turnTimeout                    0
  TURN_TIMEOUT                   0
  maxToolCalls                   0
  toolCallLimit                  0
  MAX_TOOL_CALLS                 0
  TOOL_CALL_LIMIT                0
  TOKEN_BUDGET                   0
  maxTokenBudget                 0
  totalTokenLimit                0
  wallClock                      0
  wallClockLimit                 0
  executionTimeout               0
  EXECUTION_TIMEOUT              0
  subAgentTimeout                0
  subagentTimeout                0
  SUBAGENT_TIMEOUT               0
  agentTimeout                   0
  AGENT_TIMEOUT                  0
```

The nine control rows are names known present at capture; the twenty-one absence
rows are the identifiers a wall-clock, tool-call or token bound would plausibly
have used, none of which exists. If a re-run reports the absences still 0
**and** the controls near these values, the negative holds. If the controls
collapse toward 0, the grep has lost its grip on the file.

**Notes.** Three near-misses were checked and are honestly not bounds, recorded
so the next reader does not have to re-check them:

- **`maxConcurrency`, 51 occurrences, is the vendored graph runtime's batch
  option**, not a subagent knob. Its only application-region hits lie between
  13.3 MB and 13.6 MB, inside the graph runtime's step loop
  (`async tick(options = {}) { const { timeout, retryPolicy, onStepWrite, maxConcurrency } = options;`)
  and its config translation. `concurrencyLimit` (19) is likewise a vendored
  promise-queue option in the 0.5–2.8 MB SDK region.
- **`tokenBudget`, 3 occurrences, is a brute-force truncation budget**, not a
  spend cap: `tokenBudget = Math.floor(maxTokens * 0.25)` inside the
  context-overflow handler's last-resort truncation. It shrinks a context; it
  does not stop an execution.
- **`maxDurationMs`, 2 occurrences, is a polling deadline** for one evaluate
  operation (`maxDurationMs: EVALUATE_POLL_MAX_DURATION_MS`), not on the agent
  loop.

This record goes stale if a fifth graph entry point appears, if any of the four
starts passing a third option, or if any absence row starts returning hits.

---

## R-limits-3 — Establish the compaction trigger and its session scoping: a sub-execution crossing 80% tombstones the PARENT session's stored history

**Establishes:** compaction fires at **80%** projected context usage
(`SUMMARIZATION_THRESHOLD = 80`, with `TRUNCATION_THRESHOLD = 95` above it for
brute-force truncation). The detection guard contains **no** sub-execution,
depth, or session-identity test, and the custom-agent graph — the graph every
dispatched sub-agent runs — installs the full summarization cycle. When that
cycle completes, the context-reset node persists the summary **against
`state2.chatSessionId`**, and a dispatched sub-agent's `chatSessionId` **is its
parent's**, carried verbatim through the dispatch context. The write appends a
`tombstone` whose `truncatedMessageCount` is the count of **all** the target
session's effective messages and whose `effectiveFromMessageId` is that
session's **first** effective message.

**Why it matters:** this is the hardest constraint on any long-lived worker, and
it is a data-loss constraint rather than an efficiency one. A worker that
accumulates enough context to compact declares its parent's entire stored
conversation truncated and replaces it with a summary of the worker's private
task. The damage is invisible at the time — the parent's live context is
untouched — and lands on the next session load. Any drain design must therefore
keep workers **short by construction**, finishing under 80% of their own
context, rather than by convention.

**This record is deliberately NOT reproduced by command.** Triggering it means
driving a sub-execution past 80% context and destroying a real session's stored
history. The code read below establishes the mechanism completely, and the
upstream report cited under Notes supplies field measurements a code read
cannot.

**Semantic anchor:** a small `src/utils/context-projection.ts` module holds two
percentage thresholds and a pure `decideContextAction(projectedUsage)` returning
a tagged action — truncate above the higher threshold, summarize above the
lower, otherwise proceed. A detection node estimates projected usage by adding
an estimate of the pending tool responses to the current usage percentage, then
calls that decider; its early-out guard tests only whether usage is known,
whether summarization is already pending or complete, and whether the execution
is itself a summarization turn. A shared graph helper wires three nodes —
detection, summarization, context reset — into whichever graph asks for them,
and the custom-agent graph asks. The context-reset node pulls persistence and
workspace paths off the execution's shared session services, takes the **graph
state's chat session id** as the write target, and delegates to a persistence
helper that loads that session, materializes its effective messages, and appends
a two-record pair: a `tombstone` of kind `summarization` anchored on the
**first** effective message with a count of **all** of them, followed by an
assistant message carrying the summary. The manual compact handler calls the
same helper but re-reads the session first and aborts if the history moved; the
automatic path has no such guard.

**Verified against:** KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29.

**Command** (the thresholds and the decision function):

```bash
grep -boE '(SUMMARIZATION|TRUNCATION)_THRESHOLD = [0-9]+' "$bundle"
grep -boF 'function decideContextAction(projectedUsage)' "$bundle"
head -c $((4913891+340)) "$bundle" | tail -c 340
```

**Output at capture:**

```
4914515:SUMMARIZATION_THRESHOLD = 80
4914549:TRUNCATION_THRESHOLD = 95
```

```
4913891:function decideContextAction(projectedUsage)
```

```
function decideContextAction(projectedUsage) {
  if (projectedUsage >= TRUNCATION_THRESHOLD) {
    return {
      type: "truncate",
      reason: "critical_overflow",
      projectedUsage
    };
  }
  if (projectedUsage >= SUMMARIZATION_THRESHOLD) {
    return {
      type: "summarize",
      reason: "high_usage",
      projectedUsage
   <<<
```

**Command** (the detection guard — the point is what it does **not** test):

```bash
grep -boF 'function _summarizationDetectionNode(state2)' "$bundle"
head -c $((14137263+430)) "$bundle" | tail -c 430
```

**Output at capture:**

```
14137263:function _summarizationDetectionNode(state2)
```

```
function _summarizationDetectionNode(state2) {
  const hasToolResponse = state2.context.getPendingToolResponseMessage() !== void 0;
  const shouldSkip = !state2.contextUsagePercentage || state2.needsSummarization || state2.summarizationComplete || state2.execution.simulatedTurnMessage?.includes("summarizing");
  if (shouldSkip) {
    Metrics18.reportCountMetrics({ SummarizationNotNeeded: 1 });
    return { summarizationResult:<<<
```

Four disjuncts, none of them about who is executing.

**Command** (the cycle, and its installation into the graph a dispatched
sub-agent runs — four consumers, one of them the custom-agent graph):

```bash
grep -boE '(function )?addSummarizationCycle\(' "$bundle"
head -c $((14141619+790)) "$bundle" | tail -c 790
grep -boF 'graph3 = addSummarizationCycle(graph3, {' "$bundle"
head -c $((14517722+400)) "$bundle" | tail -c 400
grep -boF 'CustomAgentGraph = graph3.compile()' "$bundle"
```

**Output at capture:**

```
14141619:function addSummarizationCycle(
14517731:addSummarizationCycle(
17028852:addSummarizationCycle(
17172918:addSummarizationCycle(
```

```
function addSummarizationCycle(graph5, options) {
  const entryNode = options.entryNode ?? "MODEL_INVOKE";
  graph5 = graph5.addNode("SUMMARIZATION_DETECTION", summarizationDetectionNode);
  graph5 = graph5.addNode("SUMMARIZATION_NODE", summarizationNode);
  graph5 = graph5.addNode("CONTEXT_RESET", contextResetNode);
  graph5 = graph5.addEdge(entryNode, "SUMMARIZATION_DETECTION");
  graph5 = graph5.addConditionalEdges("SUMMARIZATION_DETECTION", options.detectionRouter, options.routerTargets);
  graph5 = graph5.addConditionalEdges("SUMMARIZATION_NODE", createPostSummarizationRouter(options.terminationTarget), [
    options.terminationTarget,
    "CONTEXT_RESET"
  ]);
  graph5 = graph5.addEdge("CONTEXT_RESET", options.continueTarget);
  return graph5;
}
var init_add_summarization_c<<<
```

```
14517722:graph3 = addSummarizationCycle(graph3, {
```

```
graph3 = addSummarizationCycle(graph3, {
      detectionRouter: summarizationDetectionRouter2,
      terminationTarget: "USER_HOOK_AGENT_STOP",
      continueTarget: "MODEL_INVOKE",
      routerTargets: ["USER_HOOK_AGENT_STOP", "MODEL_INVOKE", "SUMMARIZATION_NODE", "REMIND_RESPONSE"]
    });
    graph3 = graph3.addConditionalEdges("USER_HOOK_AGENT_STOP", userHookAgentStopRouter2, ["MODEL_INVOKE", <<<
```

```
14518133:CustomAgentGraph = graph3.compile()
```

That last line is what makes `graph3` load-bearing rather than incidental: the
builder that received the summarization cycle is compiled into
`CustomAgentGraph`, which is the graph R-limits-1 shows a dispatched sub-agent
invoking.

**Command** (the write target and the tombstone's shape — quoted verbatim
because the exact field names are what a forensic scan of a session file needs):

```bash
grep -boE 'persistCompactionSummary[^;]{0,30}' "$bundle"
grep -boF 'async function contextResetNode(state2)' "$bundle"
head -c $((14124212+900)) "$bundle" | tail -c 900
grep -boF '// src/agent-context/summarization/persist-compaction.ts' "$bundle"
head -c $((13813808+1290)) "$bundle" | tail -c 1290
```

**Output at capture:**

```
13813932:persistCompactionSummary(params) {
14124664:persistCompactionSummary({
20617912:persistCompactionSummary({
```

```
14124212:async function contextResetNode(state2)
```

```
async function contextResetNode(state2) {
  const summary = state2.conversationSummary;
  if (!summary) {
    logger.warn("[ContextReset] No conversation summary available, ending");
    return {};
  }
  logger.info(`[ContextReset] Rebuilding context with summary (${summary.length} chars)`);
  const { persistence, workspacePaths } = state2.execution.sessionServices;
  const sessionId = state2.chatSessionId;
  if (sessionId) {
    try {
      await persistCompactionSummary({
        sessionId,
        workspacePaths,
        persistence,
        summary,
        executionId: state2.execution.executionId
      });
    } catch (err) {
      logger.warn(
        "[ContextReset] Failed to write tombstone — context will reset in-memory but session reload will replay full history",
        err
      );
    }
  }
  const context3 = rebuildContextAfterCompaction(state2.context.messages, summ<<<
```

```
13813808:// src/agent-context/summarization/persist-compaction.ts
```

```
// src/agent-context/summarization/persist-compaction.ts
import { randomUUID as randomUUID5 } from "crypto";
async function persistCompactionSummary(params) {
  const { sessionId, workspacePaths, persistence, summary, executionId, snapshot } = params;
  let firstMessageId;
  let effectiveMessageCount;
  if (snapshot) {
    firstMessageId = snapshot.firstMessageId;
    effectiveMessageCount = snapshot.effectiveMessageCount;
  } else {
    const session = await persistence.loadSession(sessionId, workspacePaths);
    if (!session) {
      return;
    }
    const effectiveMessages = materializeForAgent(session.messages);
    if (effectiveMessages.length === 0) {
      return;
    }
    firstMessageId = effectiveMessages[0].id;
    effectiveMessageCount = effectiveMessages.length;
  }
  const now = (/* @__PURE__ */ new Date()).toISOString();
  const tombstoneMessage = {
    id: `tombstone_summarize_${randomUUID5()}`,
    timestamp: now,
    payload: {
      type: "tombstone",
      kind: "summarization",
      effectiveFromMessageId: firstMessageId,
      metadata: {
        truncatedMessageCount: effectiveMessageCount,
        truncatedAt: now
      }
    }
  };
  const summaryPayload = {
    type: "assistant",
    content: summary,
    operationType: "Summary",
    ...exec<<<
```

Note the third `persistCompactionSummary` call site at 20617912: that is the
manual path, and it is the one that guards itself. Its distinguishing string is
`compaction.aborted_history_changed`, absent from the automatic path.

**Command** (the last link: the child's `chatSessionId` is the parent's, set at
the dispatch context and carried into the child's definition):

```bash
grep -boF 'chatSessionId: state2.execution.chatSessionId' "$bundle" \
  | awk -F: '$1>18000000 && $1<18050000'
head -c $((18030335+60)) "$bundle" | tail -c 200
grep -boF 'chatSessionId: subAgentDefinition.chatSessionId' "$bundle"
```

**Output at capture:**

```
18030335:chatSessionId: state2.execution.chatSessionId
```

```
ssages.push(...fileTreeContext);
      }
      const dispatchCtx = {
        prompt,
        systemPrompt,
        contextMessages,
        chatSessionId: state2.execution.chatSessionId,
        auton<<<
```

```
18037717:chatSessionId: subAgentDefinition.chatSessionId
```

Together with R-limits-1's `finalizeBuildState` window — which returns
`chatSessionId` into the child's graph state alongside the iteration limit — the
chain is closed: parent session id -> dispatch context -> child definition ->
child execution -> child graph state -> `persistCompactionSummary` write target.

**Positive controls:** this record asserts a presence (the write happens and is
session-scoped) plus one narrow absence (the detection guard has no
sub-execution test). The controls for the absence half are the ones in the
sibling `concurrency-and-nesting.md` record, R-nesting-3: `subExecutionDepth`
present with 6 occurrences and exactly one comparison on the field, and
`isSubExecution` / `isRootSession` / `isSubAgent` all zero. Re-run those
alongside this record; if they still hold, the guard still has nothing to test
with.

**Notes.** The upstream report is `kirodotdev/Kiro#10482`, "Kiro IDE + kiro-cli
v3: sub-agent compaction truncates the parent session (+ patches)" — **state
`open`** when queried on 2026-07-29, labelled `compaction` / `cli` /
`sub-agents` / `pending-maintainer-response`, filed against kiro-cli
2.14.1–2.14.2 and Kiro IDE 1.0.228, quoting the same two functions this record
windows. It supplies the field measurements: on the reporter's own installs,
**148 of 210** summarization tombstones across **16 of 171** IDE sessions, and
**104 of 118** across **10 of 47** kiro-cli v3 sessions, were attributable to
sub-executions. It also records a second, separate symptom: the sub-agent event
forwarder's `skippedEventTypes` set filters the terminal
`AgentExecutionSummarizationComplete` event but cannot filter the **opening**
phase, which rides the shared `AgentExecutionAction` type — so the parent client
latches a compaction indicator that never resolves and silently swallows later
prompts. That set is readable in one window, and the asymmetry is visible in it:

```bash
grep -boF 'var skippedEventTypes' "$bundle"
head -c $((18018605+430)) "$bundle" | tail -c 400
```

```
18018605:var skippedEventTypes
```

```
var skippedEventTypes = /* @__PURE__ */ new Set([
  "AgentExecutionQueued",
  "AgentExecutionBegan",
  "AgentExecutionResumed",
  "AgentExecutionYielded",
  "AgentExecutionSaveState",
  "AgentExecutionSuccess",
  "AgentExecutionFailed",
  "AgentExecutionAborted",
  "AgentExecutionContextUsageUpdate",
  "AgentExecutionSummarizationComplete",
  "AgentExecutionRecap",
  "AgentExecutionWaitingForActiveSlot"
]);
```

Twelve members: the terminal summarization event is in the set, and no opening
one is, because there is no distinct type for it.

This record goes stale if the detection guard gains a depth or execution-kind
test, if the context-reset node's write target changes from the graph state's
chat session id, if the tombstone gains an execution id of its own, or if either
threshold literal moves. The last is the most likely and the most misleading: a
threshold change would not fix the scoping, so **do not read a changed 80 as a
fix.**

---

## R-limits-4 — Establish that sub-executions are in-process objects, not OS processes

**Establishes:** dispatching a sub-agent constructs a JavaScript object and
calls a method on it. There is exactly one construction site **on the sub-agent
path** (three in the bundle overall — root session, workflow step driver,
sub-agent), it is `new` on a plain class, three of its fields are the **parent's
own objects passed by reference**, and the parent registers the child in a `Map`
of live object references. The module that does all this contains **zero**
process-spawn primitives.

**Why it matters:** this retires the assumption that heavy dispatch churn leaks
OS processes, and it inverts a design conclusion. If a sub-execution were a
process, one-item-per-execution recycling would be the expensive option; because
it is an object, recycling costs a constructor call, and short recycled workers
— which R-limits-3 makes mandatory anyway — become free rather than wasteful.
The by-reference sharing is the other half: it is _why_ R-limits-3's compaction
reaches the parent's persistence at all, since the child writes through the
parent's own session services object.

**Semantic anchor:** in the invoke-subagent tool's handler, after the depth
gate, a sub-agent execution is constructed with `new` on the same execution
class the root session uses. Its option literal mixes fields taken from the
resolved sub-agent definition (handler, execution id, chat session id, titles)
with three fields read straight off the **parent's** execution — session
services, prompt context, and abort signal — plus the incremented depth and the
agent name. The handler field is itself a closure invoking the definition
in-process. The parent then calls a register-child method that adds the child's
id to a `Set` **and the child object itself to a `Map`**, fires the dispatch off
with a bare `void child.invoke()`, and awaits a completion promise on the same
object. No serialization boundary appears anywhere on this path.

**Verified against:** KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29.

**Command** (the construction sites, then the sub-agent module extracted to a
small file so the reads below can be line-oriented without ever loading the 20.8
MB bundle):

```bash
grep -boE 'new AgentExecution\(\{?' "$bundle"
grep -boF '// src/tools/invoke-subagent.ts' "$bundle"
grep -boF '// src/tools/subagent-tool.ts' "$bundle"
mod=$(mktemp); head -c 18047849 "$bundle" | tail -c $((18047849-18013523)) > "$mod"
wc -c < "$mod"
grep -nE 'new AgentExecution|registerActiveChild|\.invoke\(\)|waitForCompletion' "$mod"
sed -n '539,547p' "$mod"
```

**Output at capture:**

```
16997542:new AgentExecution({
17391536:new AgentExecution({
18033147:new AgentExecution({
```

```
17711298:// src/tools/invoke-subagent.ts
17717631:// src/tools/invoke-subagent.ts
17719574:// src/tools/invoke-subagent.ts
18013523:// src/tools/invoke-subagent.ts
```

```
18047849:// src/tools/subagent-tool.ts
```

```
34326
```

```
434:      const subAgentExecution = new AgentExecution({
539:      state2.execution.registerActiveChild(subAgentExecution);
545:      void subAgentExecution.invoke();
546:      const result = await subAgentExecution.waitForCompletion();
697:        state2.execution.unregisterActiveChild(subExecutionId);
```

```
      state2.execution.registerActiveChild(subAgentExecution);
      childRegistered = true;
      emitAction("Running" /* Running */, {
        output: { response: "", subExecutionId },
        hideSubagentExecution
      });
      void subAgentExecution.invoke();
      const result = await subAgentExecution.waitForCompletion();
      parentEventSink.unregisterSubAgentExecution(subAgentExecution.executionId);
```

The three `new AgentExecution` offsets classify by neighborhood: 16997542 is a
session-level `consumeNewExecution(...)`, 17391536 is the workflow session
driver's `workflow.session_driver.starting_step` path, and 18033147 is the
sub-agent path, inside the extracted module. Only the last is relevant here, and
it is unique within that module.

**Command** (the parent holds the child object, not a handle; and the class is a
plain class):

```bash
grep -boE '(var|class) AgentExecution[^;{]{0,20}' "$bundle"
grep -boE 'activeChildExecutions[a-zA-Z]* = [^;]{0,40}' "$bundle"
grep -boE 'registerActiveChild\(execution\)' "$bundle"
head -c $((16940194+300)) "$bundle" | tail -c 400
```

**Output at capture:**

```
16932040:var AgentExecution = class
```

```
16939980:activeChildExecutions = /* @__PURE__ */ new Map()
```

```
16940194:registerActiveChild(execution)
```

```
ropagation.
   * Manages both activeChildExecutionIds and activeChildExecutions atomically.
   */
  registerActiveChild(execution) {
    this.activeChildExecutionIds.add(execution.executionId);
    this.activeChildExecutions.set(execution.executionId, execution);
  }
  /**
   * Unregisters a child execution after completion or cleanup.
   * Manages both activeChildExecutionIds and activeChildExecu<<<
```

`this.activeChildExecutions.set(execution.executionId, execution)` is the
decisive line: the value stored is the execution **object**, not a pid or a
handle.

**Positive controls:** the load-bearing half of this record is an absence — no
process-spawn primitive on the dispatch path — so it needs controls in both
directions: the primitives must be shown absent from the module **and** present
elsewhere in the same bundle, read by the same method.

```bash
occm() { { grep -boF "$1" "$mod" || true; } | wc -l; }
occb() { { grep -boF "$1" "$bundle" || true; } | wc -l; }
printf '%-28s %8s %8s\n' NEEDLE module bundle
for s in 'child_process' 'spawn(' 'spawnSync' 'execFile' 'worker_threads' \
         'StdioClientTransport' 'new AgentExecution' 'exec' 'await'; do
  printf '%-28s %8s %8s\n' "$s" "$(occm "$s")" "$(occb "$s")"; done
```

```
NEEDLE                         module   bundle
child_process                       0       18
spawn(                              0       10
spawnSync                           0        9
execFile                            0       29
worker_threads                      0        9
StdioClientTransport                0        3
new AgentExecution                  1        3
exec                              104     3733
await                             13     4446
```

The last two rows are the discriminating controls and they are the point of the
table: the module contains **104** occurrences of `exec` — every one a substring
of `execution`, `executionId`, `subExecutionDepth` — and **13** `await`s, so the
grep is plainly reading real code, yet zero of the six spawn primitives, every
one of which the wider bundle does contain. A future re-run that reports every
row as 0 has lost the file, not discovered a rewrite.

**Notes.** MCP servers **are** separate processes — that is what the bundle's
`child_process` and stdio-transport hits are for — and the known upstream
process-leak reports concern MCP child processes held by a session, not
sub-executions as such. So "dispatch churn leaks no processes" is true only for
an MCP-free worker role; a role that declares its own servers reintroduces the
question, and whether a sub-agent starts its own declared servers is the one
limit question no code read here settled. This record goes stale if a second
`new AgentExecution` appears inside the invoke-subagent module, if the child
stops receiving the parent's session services by reference, or if any spawn
primitive turns up in that module.

---

## R-limits-5 — Establish the negative: the settings surface has no per-subagent timeout, budget, or concurrency key

**Establishes:** the typed agent-settings schema shipped with KAS 2.15.1 has
exactly **31** keys, and the CLI's own settings builder forwards exactly **23**
distinct settings keys into it. **None** of the 31 and none of the 23 is a
subagent timeout, a work budget, or a concurrency ceiling. The three
subagent-related keys (`_subagent`, `_delegate`, `subagentOrchestration`) are
bare `{enabled: boolean}` feature flags. The only key in either set that is a
budget at all is `sessionEviction.maxBytes`, and it bounds **on-disk session
storage** (default 500 MB), not execution work.

**Why it matters:** R-limits-1 and R-limits-2 establish the engine's ceilings;
this record establishes that none of them is configurable. A drain design cannot
set a per-worker deadline or spend cap through settings, so worker cost has to
be bounded by what the worker is handed — one item, a short prompt — rather than
by a knob. It also fixes where the concurrency limit of 5 lives: in a compiled
constant, not a setting, so it cannot be raised.

**Semantic anchor:** two surfaces at opposite ends of one wire. On the KAS side,
a vendored type-covenant package declares a base setting schema of a single
boolean `enabled`, four extended schemas that add typed sub-options (tool-search
deferral thresholds, knowledge-index globs and chunking, compaction exclusion
percentages, a session-eviction byte budget), and one large object schema whose
properties are the settings key space, grouped by comment banners into
experimental flags (underscore-prefixed) and stable flags, each documented with
a `@see kiro-cli:` back-reference to the CLI setting it mirrors. That object is
then made permissive with a `catchall`, and its shape is re-exported as a map of
known key schemas. On the CLI side, the launcher's embedded client builds the
settings object it sends at initialize from a **fixed array of
`[cliSettingKey, kasSettingName]` pairs** plus a handful of hard-coded defaults
and three conditional pushes, then reads four families of typed sub-option keys
individually. Anything not in that array or those four blocks is not forwarded,
whatever the schema permits.

**Verified against:** KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29.

**Command** (the KAS key space, enumerated by bounding the schema object with
its own opening and closing lines rather than with hardcoded offsets):

```bash
start=$(grep -boF 'BaseAgentSettingsSchema = external_exports2.object({' "$bundle" | cut -d: -f1)
end=$(grep -boF 'AgentSettingsSchema = BaseAgentSettingsSchema.catchall' "$bundle" | cut -d: -f1)
echo "start=$start end=$end span=$((end-start))"
head -c "$end" "$bundle" | tail -c $((end-start)) \
  | grep -oE '^      [_a-zA-Z][A-Za-z0-9]*:' | tr -d ' :' | tr '\n' ' '; echo
head -c "$end" "$bundle" | tail -c $((end-start)) \
  | grep -coE '^      [_a-zA-Z][A-Za-z0-9]*:'
```

**Output at capture:**

```
start=872016 end=883684 span=11668
_parallelTasks _steeringReminders _sessionRecap _mergeVibeSpec _requirementAnalyzer _c2s _quickSpec _subagent _delegate thinking tangentMode disableAutoCompaction codeIntelligence subagentOrchestration inlineAgents todoList checkpoint semanticReview fta goal workflows specPlan steeringSupervisor infraSafetyMonitor infraSafetyEnforce _providerPowers largeToolOutputHandler toolSearch knowledge sessionEviction compaction
31
```

**Command** (the four typed sub-option schemas — the only places a numeric knob
exists at all, so this is where a budget would have to appear):

```bash
grep -boF 'ToolSearchSettingSchema = createToolConfigSchema({' "$bundle"
head -c $((869827+2200)) "$bundle" | tail -c 2200
```

**Output at capture:**

```
869827:ToolSearchSettingSchema = createToolConfigSchema({
```

```
ToolSearchSettingSchema = createToolConfigSchema({
      /** Minimum percentage of context window that tool specs must occupy before deferral activates. */
      minPct: external_exports2.number().min(0).max(100).optional(),
      /** Minimum token count of tool specs before deferral activates (OR with minPct). */
      minTokens: external_exports2.number().min(0).optional(),
      /** Tool IDs that should never be deferred (always loaded into context). */
      neverDefer: external_exports2.array(external_exports2.string()).optional()
    });
    KnowledgeSettingSchema = createToolConfigSchema({
      /** Glob patterns for files to include in the knowledge index. */
      includePatterns: external_exports2.array(external_exports2.string()).optional(),
      /** Glob patterns for files to exclude from the knowledge index. */
      excludePatterns: external_exports2.array(external_exports2.string()).optional(),
      /** Maximum number of files to index. */
      maxFiles: external_exports2.number().min(1).optional(),
      /** Size of each text chunk in words for embedding. */
      chunkSize: external_exports2.number().min(64).optional(),
      /** Overlap between adjacent chunks in words. */
      chunkOverlap: external_exports2.number().min(0).optional(),
      /** Index algorithm: 'fast' (BM25 keyword) or 'best' (semantic embeddings). 'accurate' is a legacy alias for 'best'. */
      indexType: external_exports2.enum(["fast", "best", "accurate"]).optional()
    });
    CompactionSettingSchema = createToolConfigSchema({
      /** Percentage of context window to exclude from compaction (preserves recent context). */
      excludePercent: external_exports2.number().min(0).max(100).optional(),
      /** Number of most recent messages to exclude from compaction. */
      excludeMessages: external_exports2.number().min(0).optional()
    });
    SessionEvictionSettingSchema = createToolConfigSchema({
      /**
       * Maximum total session storage in bytes before least-recently-modified
       * sessions are evicted. Omit to use the agent's default budget (500 MB).
       */
      maxBytes: external_exports2.number().int().min(1).optional()
    });
    BaseAgentSe<<<
```

Eleven numeric or array options across four schemas, and not one of them is
about execution work: three tune tool-spec deferral, six tune a knowledge index,
two tune which messages compaction preserves, one caps session storage on disk.

**Command** (the CLI side of the wire — the fixed allowlist, and every settings
key it reads):

```bash
o=$(grep -aboF 'KIRO_TEST_DISABLE_SUBAGENT_ORCHESTRATION' "$rustchat" | head -1 | cut -d: -f1)
echo "o=$o"
head -c $((o+880)) "$rustchat" | tail -c 1000 | tr -c '[:print:]\n' '.'
head -c $((o+2450)) "$rustchat" | tail -c 2500 \
  | grep -oE '"(chat|toolSearch|compaction|knowledge)\.[A-Za-z0-9]+"' | tr -d '"' | sort -u | tr '\n' ' '; echo
head -c $((o+2450)) "$rustchat" | tail -c 2500 \
  | grep -coE '"(chat|toolSearch|compaction|knowledge)\.[A-Za-z0-9]+"'
```

**Output at capture:**

```
o=396741449
```

```
ed:!0}}function qCe(){let e=wa(),n={},t={codeIntelligence:!0,knowledge:!0,thinking:!0,subagentOrchestration:process.env.KIRO_TEST_DISABLE_SUBAGENT_ORCHESTRATION!=="1"},a=[["chat.enableThinking","thinking"],["chat.enableKnowledge","knowledge"],["chat.enableCodeIntelligence","codeIntelligence"],["chat.enableTodoList","todoList"],["chat.enableCheckpoint","checkpoint"],["chat.enableTangentMode","tangentMode"],["chat.disableAutoCompaction","disableAutoCompaction"],["chat.enableSubagent","_subagent"],["chat.enableDelegate","_delegate"]];if(process.env.KIRO_INFRA_SAFETY_ROLLOUT_ENABLED==="1")a.push(["chat.enableInfraSafetyMonitor","infraSafetyMonitor"],["chat.enableInfraSafetyEnforce","infraSafetyEnforce"]);if(no.isEnabled("c2s"))a.push(["chat.enableC2s","c2s"]);for(let[s,A]of a){let d=e[s];if(typeof d==="boolean")n[A]={enabled:d}}for(let[s,A]of Object.entries(t))if(!(s in n))n[s]={enabled:A};X0n(n);let i=e["toolSearch.enabled"];if(typeof i==="boolean"){let s={enabled:i},A=e["toolSearch.minPc<<<
```

```
chat.disableAutoCompaction chat.enableC2s chat.enableCheckpoint chat.enableCodeIntelligence chat.enableDelegate chat.enableInfraSafetyEnforce chat.enableInfraSafetyMonitor chat.enableKnowledge chat.enableSubagent chat.enableTangentMode chat.enableThinking chat.enableTodoList compaction.excludeContextWindowPercent compaction.excludeMessages knowledge.chunkOverlap knowledge.chunkSize knowledge.defaultExcludePatterns knowledge.defaultIncludePatterns knowledge.indexType knowledge.maxFiles toolSearch.enabled toolSearch.minPct toolSearch.minTokens
```

```
24
```

23 distinct keys across 24 occurrences (`chat.enableKnowledge` is read twice —
once as a boolean pair, once as the gate for the knowledge sub-options). Note
that `subagentOrchestration` is **defaulted on in code** and is not settable
through this builder at all; the only lever on it is a test environment
variable. That is the closest thing in the whole surface to a subagent knob, and
it is a kill switch, not a budget. `qCe`, `wa`, `no`, `X0n` are minifier names
in embedded client JS and will churn; the durable handle is the
environment-variable literal the command greps for.

**Positive controls:** this record is an absence, so a re-run must be able to
tell "the keys were removed" from "I can no longer parse the schema".

```bash
occ() { { grep -boF "$1" "$bundle" || true; } | wc -l; }
echo 'CONTROLS (expected non-zero)'
for s in BaseAgentSettingsSchema BaseSettingSchema SessionEvictionSettingSchema \
         subagentOrchestration disableAutoCompaction sessionEviction maxBytes \
         resolveSessionEviction; do printf '  %-30s %s\n' "$s" "$(occ "$s")"; done
echo 'ABSENCES (expected zero)'
for s in 'chat.maxSubagents' 'chat.subagentTimeout' 'chat.subagentBudget' \
         'chat.maxConcurrentSubagents' 'subagent.timeout' 'subagent.maxConcurrent' \
         'subagent.budget' 'subagent.maxTurns' 'agent.timeout' 'agent.budget'; do
  printf '  %-30s %s\n' "$s" "$(occ "$s")"; done
```

```
CONTROLS (expected non-zero)
  BaseAgentSettingsSchema        4
  BaseSettingSchema              30
  SessionEvictionSettingSchema   3
  subagentOrchestration          4
  disableAutoCompaction          2
  sessionEviction                4
  maxBytes                       19
  resolveSessionEviction         3
ABSENCES (expected zero)
  chat.maxSubagents              0
  chat.subagentTimeout           0
  chat.subagentBudget            0
  chat.maxConcurrentSubagents    0
  subagent.timeout               0
  subagent.maxConcurrent         0
  subagent.budget                0
  subagent.maxTurns              0
  agent.timeout                  0
  agent.budget                   0
```

The same absence set was measured against both Rust binaries and returned 0 in
each, with `chat.enableSubagent` (3 in the chat binary) and
`chat.disableAutoCompaction` (4) as the controls proving settings-key strings
are findable there.

**Notes — a second finding this record turned up, worth as much as the primary
one.** Two of the forwarded key families are **declared, forwarded, and never
read** by KAS 2.15.1:

```bash
grep -boE 'disableAutoCompaction[^;,)]{0,45}' "$bundle"
grep -boE '(excludePercent|excludeMessages)[^;,)]{0,45}' "$bundle"
grep -boE "isFeatureEnabled\(['\"][A-Za-z_]+['\"]\)" "$bundle" \
  | awk -F: '{print $2}' | sort -u | tr '\n' ' '
```

```
874905:disableAutoCompaction` (stable
874967:disableAutoCompaction: BaseSettingSchema.optional(
```

```
871479:excludePercent: external_exports2.number(
871628:excludeMessages: external_exports2.number(
883592:excludeMessages`
```

```
isFeatureEnabled("infraSafetyEnforce") isFeatureEnabled('infraSafetyEnforce') isFeatureEnabled("infraSafetyMonitor") isFeatureEnabled('infraSafetyMonitor') isFeatureEnabled("largeToolOutputHandler") isFeatureEnabled('largeToolOutputHandler') isFeatureEnabled("memoryEnable") isFeatureEnabled("mergeVibeSpec") isFeatureEnabled('parallelTasks') isFeatureEnabled('quickSpec') isFeatureEnabled('requirementAnalyzer') isFeatureEnabled('sessionRecap') isFeatureEnabled("sessionRecap") isFeatureEnabled("steeringReminders") isFeatureEnabled("subagentOrchestration") isFeatureEnabled('toolSearch') isFeatureEnabled("verifyFirstWorkflow") isFeatureEnabled('_providerPowers')
```

Every occurrence of `disableAutoCompaction` and of the two compaction
sub-options is inside the settings-schema module — a doc comment and a
declaration — and `isFeatureEnabled` is never called with
`"disableAutoCompaction"`. Contrast `sessionEviction`, whose value **is**
resolved and consumed (`resolveSessionEviction`, then a storage-budget check).
So `chat.disableAutoCompaction` is, on the v3 engine in this build, an **inert
setting**: it exists, the CLI forwards it, and nothing reads it. Anyone hoping
to dodge R-limits-3 by disabling compaction should expect no effect. The one
compaction override that is live, `compactionConfigOverride`, is a graph-state
channel set only from the internal brute-force overflow path.

This record goes stale the moment a typed Kiro agents surface is added anywhere
downstream, because at that point these key lists stop being evidence and become
config — which is the documented condition for replacing a record like this with
an extracted, drift-checked option surface. Short of that, it goes stale if the
schema gains a 32nd key, if the allowlist array grows, or if
`isFeatureEnabled("disableAutoCompaction")` starts appearing.

---

## R-engine-1 — Establish the engine split — and CORRECT it: the Rust binaries carry no workflow machinery, but the v2 chat binary carries a complete hook engine of its own

**Establishes:** two claims, and they do not both survive.

- **Workflow machinery: confirmed absent from the Rust binaries.** All five
  workflow tool names and the session flag that gates them return **zero** hits
  in both wrapped Rust binaries (and in the third, the terminal helper), while
  returning 5–26 hits each in the KAS bundle. The workflow surface is KAS-only.
- **Hook machinery: the "no hook machinery in the Rust binaries" claim is NOT
  reproducible.** The 555 MB v2 chat binary contains its own hook engine in its
  **Rust** region — a wire hook document type, a two-variant hook action enum, a
  trigger enum whose variants are `AgentSpawn` / `PrePrompt` / `PreToolUse` /
  `PostToolUse`, the matching lower-camel wire names, an `ExecutingHooks`
  execution state, and blocking error strings. What is genuinely v3-specific is
  the **larger trigger set**: the file-event and prompt-submit triggers, the
  `skipHooks` gate, the `dispatchKind` adapter selector, and the structured
  `hookSpecificOutput` protocol are all KAS-only.

**Why it matters:** the corrected version is the more useful one. "Hooks are a
KAS feature" would predict that a v2 session has no hooks at all; in fact v2 has
four triggers and v3 has more, so a hook document written for one engine can
load on the other and silently do less. The v3-only names are the discriminator
worth remembering: if a trigger name appears in the KAS bundle and **not** in
the chat binary's Rust region, it is v3-only. The workflow half, being a clean
negative, carries the design consequence: there is no Rust-side path to the
workflow tools at all, so the only way to reach them is through KAS session
state.

**Semantic anchor:** three ELF binaries ship — a launcher, the v2 chat engine,
and a terminal helper. The v2 chat engine's Rust string tables carry
serde-derived type names for a hook document and a hook action with agent and
command variants, a set of per-tool settings structs beside them, an agent
execution state named for running hooks sitting next to one named for waiting on
approval, and two user-facing failure strings about a pre-tool hook blocking a
call. The KAS bundle carries a different and larger vocabulary: a trigger alias
table, a per-node `skipHooks` short-circuit, an agent-profile `dispatchKind`
discriminator, file-event triggers, and a structured hook-output envelope. The
chat binary **also** embeds a JavaScript bundle — the v3 client — high in the
file, and that region carries the v3 trigger _names_ as a five-member set used
for permission mapping, plus the settings allowlist of R-limits-5, but no hook
_execution_.

**Verified against:** KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), plus `.kiro-cli-wrapped` (53809000 bytes) and
`.kiro-cli-chat-wrapped` (555372744 bytes) from kiro-cli 2.15.1, 2026-07-29.

**Command:**

```bash
occ() { { grep -aboF "$1" "$2" || true; } | wc -l; }
row() { printf '  %-40s %6s %6s %6s\n' "$1" \
  "$(occ "$1" "$rustmain")" "$(occ "$1" "$rustchat")" "$(occ "$1" "$bundle")"; }
printf '  %-40s %6s %6s %6s\n' NEEDLE main chat KAS
echo 'A. workflow tool names'
for s in run_workflow inspect_workflow update_workflow validate_workflow \
         save_workflow_definition workflowsEnabled; do row "$s"; done
echo 'B. v3-only hook names'
for s in UserPromptSubmit PostFileCreate PostFileSave PostFileDelete \
         hookSpecificOutput skipHooks dispatchKind; do row "$s"; done
echo 'C. hook names v2 also uses'
for s in PreToolUse PostToolUse AgentSpawn PrePrompt; do row "$s"; done
echo 'D. v2 hook machinery'
for s in WireHookDocument WireHookAction ExecutingHooks \
         'Error found in PreToolUse hooks'; do row "$s"; done
echo 'E. positive controls'
for s in kiro-cli mcp.json use_subagent.rs invoke_sub_agent toolSearch; do row "$s"; done
```

**Output at capture:**

```
  NEEDLE                                     main   chat    KAS
A. workflow tool names
  run_workflow                                  0      0     26
  inspect_workflow                              0      0      7
  update_workflow                               0      0     10
  validate_workflow                             0      0      5
  save_workflow_definition                      0      0     12
  workflowsEnabled                              0      0     14
B. v3-only hook names
  UserPromptSubmit                              0      1     36
  PostFileCreate                                0      0     23
  PostFileSave                                  0      0     26
  PostFileDelete                                0      0     22
  hookSpecificOutput                            0      0      4
  skipHooks                                     0      0     29
  dispatchKind                                  0      0     16
C. hook names v2 also uses
  PreToolUse                                    0      8     77
  PostToolUse                                   0      7     48
  AgentSpawn                                    0      6      0
  PrePrompt                                     0      3      0
D. v2 hook machinery
  WireHookDocument                              0     43      0
  WireHookAction                                0     28      0
  ExecutingHooks                                0      9      0
  Error found in PreToolUse hooks               0      1      0
E. positive controls
  kiro-cli                                    196    250     27
  mcp.json                                      5     17     10
  use_subagent.rs                               0      6      0
  invoke_sub_agent                              0      5     31
  toolSearch                                    0     15     33
```

**Command** (the classification that turns row group C from a puzzle into a
finding — v2's hook engine, read out of the Rust region):

```bash
grep -aboF 'PreToolUse' "$rustchat"
for o in 5566096 5598747 7049472; do
  echo "--- $o ---"
  head -c $((o+200)) "$rustchat" | tail -c 420 | tr -c '[:print:]\n' '.'
  echo
done
```

**Output at capture:**

```
5566096:PreToolUse
5600614:PreToolUse
7049472:PreToolUse
397536180:PreToolUse
397548550:PreToolUse
398681187:PreToolUse
399209663:PreToolUse
399444513:PreToolUse
```

```
--- 5566096 ---
tes/agent/src/agent/mod.rs:1117event crates/agent/src/agent/mod.rs:1171event crates/agent/src/agent/mod.rs:1128failed to process path ... reads modifications1 modification, 1 read modifications, 1 readAgentSpawnPrePromptPreToolUsetoolsneeds_approvaltrust_options_mappre_built_contentpre_built_resultsPostToolUseexecuting_toolsuser_turn_metadataErroredWaitingForApprovalExecutingHooksempty_response_retriedpending_user_me

--- 5598747 ---
mandHookstruct GlobSettingsstruct GrepSettingstool_namestruct ToolsSettingsstruct FsReadSettingsstruct UseAwsSettingsstruct variant WireHookAction::Agentstruct variant WireHookAction::Commandstruct FsWriteSettingscommandagentSpawnpreToolUsepostToolUsevariant index 0 <= i < 5struct WebFetchSettingsstruct WireHookDocumentstruct DetectorConfigstruct AgentCrewSettingsstruct ExecuteCmdSettingsfsReadfs_readfsWritewriteexec

--- 7049472 ---
hen stdin is piped.
Validating tool usesFailed to validate tool parameters: Error found in the model tools [DETAILS] Tool '' execution skipped due to validation failures in other toolsNo utterance id foundError found in PreToolUse hooksPreToolHook blocked the tool execution: failed to serialize tool result contentTool validation failed: ctrlc received in compact historyinternal error: entered unreachable code: failed
```

Three things are visible and none is ambiguous: an execution-state enum
containing `ExecutingHooks` beside `WaitingForApproval` and `Errored`; serde
type names for `WireHookDocument` and `WireHookAction::{Agent,Command}` (with
the wire names `agentSpawn`, `preToolUse`, `postToolUse` interned right after);
and runtime error strings `Error found in PreToolUse hooks` and
`PreToolHook blocked the tool execution`. That is a hook engine, not a stray
identifier. All three offsets sit below 7.1 MB, in the Rust region. The
`mandHook` at the head of the second window is a truncated `struct CommandHook`.

**Command** (the other side of the split — what the _embedded JS_ region
carries, so the two are not confused):

```bash
grep -aboF 'userPromptSubmit' "$rustchat"
head -c $((396401825+120)) "$rustchat" | tail -c 300 | tr -c '[:print:]\n' '.'
```

**Output at capture:**

```
5230576:userPromptSubmit
396401825:userPromptSubmit
```

```
y.from(t).sort().map((r)=>({capability:r,effect:"allow"}));if(a.size>0)i.push({capability:"mcp",match:Array.from(a).sort(),effect:"allow"});return i}var nBn=new Set(["agentSpawn","userPromptSubmit","preToolUse","postToolUse","stop"]);function UBe(e,n){if(Array.isArray(e))return e;if(OBe(e))return tB<<<
```

So the chat binary's single `UserPromptSubmit` hit — at 5230576, in an interned
ACP type-name blob beside `ListToolsRequest` and `ContentBlockStop` — is
protocol vocabulary, while the **five-member** v3 trigger set at 396401825 is
embedded client JS doing permission mapping. Neither is hook execution.

**Positive controls:** row group E is the control set, and it is chosen so each
zero in the table sits beside a non-zero read from the same file by the same
method. `kiro-cli` and `mcp.json` are present in all three columns;
`use_subagent.rs` (6) and `invoke_sub_agent` (5) are present in the chat binary,
proving a grep of that file finds subagent code; `toolSearch` (15 / 33) and
`invoke_sub_agent` (31) cover the bundle. **Row group D doubles as the control
the hook negative specifically needs**: `WireHookDocument` at 43 in the chat
binary proves a search for hook machinery in that file _works_, which is exactly
what makes the zeros in row group B meaningful rather than an artefact.

**Notes.** Three replay traps, each of which cost a wrong answer during capture:

- **`send_message` is not a usable discriminator** and is deliberately excluded
  from row group A. It returns 59 hits in the launcher and 110 in the chat
  binary, all from a `crates/fig_ipc/src/send_message.rs` module path and
  generic method names — nothing to do with the workflow tool of the same name.
  A workflow-absence table that included it would report a false positive.
- **`SessionStart` is likewise a trap**: 10 hits in the launcher, 81 in the chat
  binary, 17 in the terminal helper, and in the launcher every one is a shell
  integration protobuf message (`NotifyChildSessionStarted`,
  `NotifySSHSessionStartedRequest`). Use the v3-only names in row group B, not
  the generically-spelled triggers.
- **Case matters, and so do digits.** `prePrompt` returns 0 in the chat binary
  while `PrePrompt` returns 3, and `chat.enableC2s` is missed entirely by a
  `[A-Za-z]+` key regex. Search both casings and allow digits.

The third binary, the terminal helper (41754304 bytes), was measured with all
twenty hook and workflow needles above and returned **0 for every one**, against
a control of `kiro-cli` at 87; it is omitted from the table only for width.

This record goes stale if a workflow name appears in any Rust binary, if v2's
hook enum gains a trigger, or if the v3-only column loses one. **The correction
it carries is the durable part: do not restate "the Rust binaries contain no
hook machinery" from an earlier note — it is false for the v2 chat engine.**
