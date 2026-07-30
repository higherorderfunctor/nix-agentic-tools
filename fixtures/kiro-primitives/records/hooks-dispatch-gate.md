# Records: hook firing in sub-executions — the gate (Kiro CLI v3)

Seven replayable records covering the canonical hook trigger vocabulary, the
absence of any subagent-lifecycle trigger, the single boolean that suppresses
prompt and stop hooks inside a dispatched sub-agent, the one-shot-vs-per-turn
trigger split, the agent-profile field that switches the suppression off, why
tool and file hooks are never suppressed, and what the child shares with its
parent. All captured against KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29.

## How to replay these

Resolve the bundle first. Seven KAS versions were installed on the capture
machine; a glob that takes the first match silently picks a stale one, so the
resolver refuses on ambiguity rather than guessing.

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

At capture `$bundle` was **20752757** bytes, matching the sibling
`concurrency-and-nesting.md` capture exactly. R-hooks-2 also reads the two
wrapped Rust binaries as `$rustchat` and `$rustterm`; it records how those paths
were resolved.

Every command below was executed on 2026-07-29 in a `set -euETo pipefail` shell
in which `$bundle` (and `$rustchat` / `$rustterm`) already held literal absolute
paths. Every byte of every "output at capture" block is real, unedited output of
the command directly above it, with `<<<` marking where a fixed-size window
truncates mid-token — the same convention the sibling record uses.

Five conventions that matter for replay, four shared with the sibling record:

- **Never `cat` the bundle.** It is 20.8 MB. Read a window with
  `head -c $((OFFSET+N)) "$bundle" | tail -c M`. That form is preferred over
  `tail -c +OFFSET | head -c N`, because the latter gives `head` a reason to
  close the pipe early and, under `pipefail`, the resulting SIGPIPE on `tail`
  fails the whole command.
- **Count occurrences as `{ grep -boF X f || true; } | wc -l`, never
  `grep -c`.** The capture machine's `grep` is **ugrep 7.5.0**, where `-c -o`
  counts occurrences while plain `-c` counts lines, so the two forms disagree.
  The `|| true` keeps a legitimate zero from failing the pipeline.
- **ugrep's `-E` is POSIX ERE — no backreferences.** `^ +([A-Za-z]+): "\1"`
  fails with `invalid escape`. R-hooks-1 classifies identity mappings with `awk`
  for that reason; do not "simplify" it back into the regex.
- **Byte offsets in these records are conveniences, not anchors.** They move on
  every rebuild. The semantic anchor is the durable part.
- **The bundle is not identifier-minified.** It is esbuild-bundled but
  pretty-printed, keeps `// src/<path>.ts` section markers, and keeps original
  names **and source comments** — several of which are quoted below and state
  the behavior outright. What _does_ churn is esbuild's collision suffixes:
  `state2`, `graph3`, `userHookOnPromptsNode2`, `external_exports2`,
  `CustomAgentExecutionDefinition2`. Never let one of those be your only handle.

---

## R-hooks-1 — Establish the closed 11-name canonical trigger vocabulary and the alias table that funnels every other spelling onto it

**Establishes:** there are exactly **11** canonical hook triggers. A single
frozen alias table holds **27** keys — the 11 canonical names mapping to
themselves plus **16** aliases from three legacy/alternate dialects — and it is
the **only** resolution surface: a trigger name absent from the table resolves
to `undefined` and the hook document is dropped with a warning.

**Why it matters:** the 11 names are the entire event surface a hook can bind
to, and the table is what makes "no such trigger" a closed question rather than
a guess. It also explains why hook files written for the IDE, for the CLI, or
against the Open Plugins spec all work: three dialects are normalized, not three
engines. Two aliases land on `SessionStart`, and one of them is named
**`agentSpawn`** — a name that reads exactly like a subagent-lifecycle event and
is nothing of the kind. That single row is the most likely source of the belief
R-hooks-2 refutes.

**Semantic anchor:** a `src/hooks/trigger-names.ts` module exports a
name-normalizing function whose whole body is a presence test against one frozen
lookup object, returning `undefined` on a miss, plus a companion canonical-name
function that is the identity. The lookup object is written in four commented
blocks: the canonical PascalCase identity mappings, the "IDE legacy camelCase
(as emitted by `.kiro.hook` `when.type`)" block, the "CLI aliases (inline
agent-profile hooks)" block, and the "Open Plugins aliases" block. Every
hook-document loader funnels its raw trigger string through that function and
discards the document when it comes back undefined.

**Verified against:** KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29.

**Command:**

```bash
head -c $((13923904+180)) "$bundle" | tail -c 195
grep -boF 'TRIGGER_ALIAS_TABLE' "$bundle"
head -c $((13924270+2400)) "$bundle" | tail -c 2400 \
  | grep -oE '^ +[A-Za-z]+: "[A-Za-z]+"' | sed -E 's/^ +//; s/: "/ -> /; s/"$//'
```

**Output at capture:**

```
);
      }
    };
  }
});

// src/hooks/trigger-names.ts
function normalizeTriggerName(name) {
  return Object.hasOwn(TRIGGER_ALIAS_TABLE, name) ? TRIGGER_ALIAS_TABLE[name] : void 0;
}
function c<<<
```

```
13924007:TRIGGER_ALIAS_TABLE
13924036:TRIGGER_ALIAS_TABLE
13924139:TRIGGER_ALIAS_TABLE
13924270:TRIGGER_ALIAS_TABLE
```

```
SessionStart -> SessionStart
Stop -> Stop
PreToolUse -> PreToolUse
PostToolUse -> PostToolUse
PreTaskExec -> PreTaskExec
PostTaskExec -> PostTaskExec
UserPromptSubmit -> UserPromptSubmit
PostFileCreate -> PostFileCreate
PostFileSave -> PostFileSave
PostFileDelete -> PostFileDelete
Manual -> Manual
sessionStart -> SessionStart
agentStop -> Stop
promptSubmit -> UserPromptSubmit
preTaskExecution -> PreTaskExec
postTaskExecution -> PostTaskExec
preToolUse -> PreToolUse
postToolUse -> PostToolUse
fileEdited -> PostFileSave
fileCreated -> PostFileCreate
fileDeleted -> PostFileDelete
userTriggered -> Manual
agentSpawn -> SessionStart
stop -> Stop
userPromptSubmit -> UserPromptSubmit
SessionEnd -> Stop
AfterFileEdit -> PostFileSave
```

The four table hits are the `Object.hasOwn` test and the index read inside
`normalizeTriggerName` (13924007 / 13924036), the hoisted `var` (13924139), and
the `Object.freeze` assignment (13924270) — no fifth consumer, so nothing
bypasses the normalizer.

**Command** (the counts, with their denominator, and the aliases landing on
`SessionStart`):

```bash
win() { head -c $((13924270+2400)) "$bundle" | tail -c 2400; }
win | grep -oE '^ +[A-Za-z]+: "[A-Za-z]+"' \
  | sed -E 's/^ +//; s/: "/ /; s/"$//' \
  | awk '{ if ($1==$2) c++; else a++ } END { print "canonical(identity): " c; print "aliases: " a; print "total: " c+a }'
win | grep -oE ': "[A-Za-z]+"' | tr -d ': "' | sort -u | wc -l
win | grep -oE '^ +[A-Za-z]+: "SessionStart"' | sed 's/^ *//'
```

**Output at capture:**

```
canonical(identity): 11
aliases: 16
total: 27
11
SessionStart: "SessionStart"
sessionStart: "SessionStart"
agentSpawn: "SessionStart"
```

**Denominator:** 27 table keys total; 11 of them are identity mappings, and the
set of distinct right-hand values is also 11 — i.e. every alias lands on a
canonical name and no canonical name is unreachable.

**Command** (the table is closed — an unrecognized trigger is dropped, loudly in
the log and silently to the model):

```bash
grep -boE 'normalizeTriggerName[^;]{0,50}' "$bundle"
head -c $((13945898+300)) "$bundle" | tail -c 620
```

**Output at capture:**

```
13923955:normalizeTriggerName(name) {
13945898:normalizeTriggerName(doc.trigger)
13958933:normalizeTriggerName(eventName)
19820615:normalizeTriggerName(trigger)
19821460:normalizeTriggerName(trigger)
20526981:normalizeTriggerName(trigger)
```

```
ts.raw);
  if (!parsed2.success) {
    opts.logger.warn("[hooks] Hook document failed schema validation", {
      id: opts.id,
      issues: parsed2.error.issues
    });
    opts.telemetry?.reportCount("hooks.invalidSchema", { source: opts.source });
    return void 0;
  }
  const doc = parsed2.data;
  const trigger = normalizeTriggerName(doc.trigger);
  if (trigger === void 0) {
    opts.logger.warn("[hooks] Hook trigger is not a recognized name", {
      id: opts.id,
      trigger: doc.trigger
    });
    opts.telemetry?.reportCount("hooks.unknownTrigger");
    return void 0;
  }
  const action = doc.action.typ<<<
```

**Positive controls:** not required for the presence claims. The _closure_ claim
("no twelfth trigger exists") is an absence and is carried by R-hooks-2, which
ships the controls.

**Notes on the corrections this record makes.**

- The brief this record was written from said **one** lowercase alias maps onto
  `SessionStart`. There are **two** — `sessionStart` (IDE legacy) and
  `agentSpawn` (CLI). The point survives and sharpens: `agentSpawn` is the
  spawn-shaped one, and it is an alias, not a trigger.
- The trigger enum is a TypeScript `const enum`, so it is **erased**: values
  appear inline as string literals with `/* Name */` comments and there is no
  runtime enum object to enumerate. The alias table's identity block is
  therefore the only enumerable form of the canonical set, which is why this
  record reads the table rather than an enum.
- The internal graph layer speaks the **camelCase** dialect (`"sessionStart"`,
  `"promptSubmit"`, `"agentStop"` — see R-hooks-4), and those strings travel
  through `normalizeTriggerName` on their way to a hook document's registered
  trigger. The canonical PascalCase names are what reach a hook's stdin as
  `hook_event_name`.
- Two of the six `normalizeTriggerName` call sites (19820615, 19821460) are in a
  separate ~19.8 MB region that bridges to a v2 hooks provider; that region is a
  different concern and is not covered by this record group.
- Goes stale if a row is added or removed, if the enum grows a twelfth member,
  or if a loader stops routing through `normalizeTriggerName`.

---

## R-hooks-2 — Establish the negative: no subagent-lifecycle hook trigger exists in either engine, and the names that DO hit are transcript payloads, not triggers

**Establishes:** there is **no** subagent-lifecycle hook trigger — nothing
resembling `SubagentStart` / `SubagentStop` in the KAS bundle or in either
wrapped Rust binary. Naive greps are **not** all-zero, and that is the trap this
record exists to defuse: `SubAgentStart` (3), `subAgentStart` (1) and
`SubAgentComplete` (5) hit in the bundle, and `SubagentSpawn` hits twice in the
Rust chat binary. Every one of those is a **transcript payload schema, an
activity-type mapping, or a permission-request flag** — none is a hook trigger.

**Why it matters:** it forecloses a whole class of design. A parent cannot be
notified of a child's start or finish by a hook, so there is no hook-based
completion event and no hook-based fan-in; the channels are files, tool-call
observation (R-hooks-6), and the dispatch return value. Equally important, the
subagent lifecycle **is** observable — just in the session transcript, not in
the hook system. Reading the naive grep hits as "a lifecycle hook exists" is the
mistake; reading them as "nothing records subagent lifecycle" is the opposite
mistake.

**Semantic anchor:** the trigger vocabulary is closed by R-hooks-1's frozen
alias table, and no row in it names a subagent event; a hook document naming one
is rejected at load with `[hooks] Hook trigger is not a recognized name`.
Separately, the persistence layer's payload-schema barrel exports a
start/complete/progress triple for sub-agents — Zod objects whose `type`
literals are the snake_case transcript record names, carrying
`parentExecutionId` / `subSessionId` / `subAgentName` — and an activity-type map
translates those snake_case record names to camelCase UI activity kinds. A
recovery path even synthesizes a completion record for a sub-agent left open by
a crashed session. All of that is journaling. In the v2 Rust chat binary the
only spawn-shaped name is a boolean field on a permission-request builder, and
it lives in the embedded minified JS region, not in the Rust hook code.

**Verified against:** KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29.

**Command** (resolving the two Rust binaries; the resolver is Nix-store-shaped
because the capture machine installs kiro-cli through Nix, and `readlink -f` is
load-bearing because `bin/kiro-cli-chat` there is a bash wrapper, not the ELF):

```bash
launcher=$(readlink -f "$(command -v kiro-cli)")
pkg=$(grep -oE '/nix/store/[a-z0-9]{32}-kiro-cli-[^/]*' "$launcher" | head -1)
for n in kiro-cli-chat kiro-cli-term; do
  b=$(readlink -f "$pkg/bin/.$n-wrapped")
  printf '%s\n  %s\n  %s bytes\n' "$n" "$b" "$(stat -c '%s' "$b")"
  file -bL "$b" | cut -c1-45
done
```

**Output at capture:**

```
kiro-cli-chat
  /nix/store/qh137p3awp4dr0am6w4i49xjlj0mrp29-kiro-cli-2.15.1/bin/.kiro-cli-chat-wrapped
  555372744 bytes
ELF 64-bit LSB pie executable, x86-64, versio
kiro-cli-term
  /nix/store/qh137p3awp4dr0am6w4i49xjlj0mrp29-kiro-cli-2.15.1/bin/.kiro-cli-term-wrapped
  41754304 bytes
ELF 64-bit LSB pie executable, x86-64, versio
```

**Command** (the search across all three files):

```bash
occ() { { grep -aboF "$1" "$2" || true; } | wc -l; }
for s in SubagentStart SubagentStop SubAgentStart SubAgentStop \
         subagentStart subagentStop subAgentStart subAgentStop \
         PreSubAgent PostSubAgent SubagentComplete SubAgentComplete \
         SubagentSpawn subagentSpawn SubagentEnd SubAgentEnd; do
  printf '%-18s bundle=%-3s chat=%-3s term=%s\n' "$s" \
    "$(occ "$s" "$bundle")" "$(occ "$s" "$rustchat")" "$(occ "$s" "$rustterm")"
done
```

**Output at capture:**

```
SubagentStart      bundle=0   chat=0   term=0
SubagentStop       bundle=0   chat=0   term=0
SubAgentStart      bundle=3   chat=0   term=0
SubAgentStop       bundle=0   chat=0   term=0
subagentStart      bundle=0   chat=0   term=0
subagentStop       bundle=0   chat=0   term=0
subAgentStart      bundle=1   chat=0   term=0
subAgentStop       bundle=0   chat=0   term=0
PreSubAgent        bundle=0   chat=0   term=0
PostSubAgent       bundle=0   chat=0   term=0
SubagentComplete   bundle=0   chat=0   term=0
SubAgentComplete   bundle=5   chat=0   term=0
SubagentSpawn      bundle=0   chat=2   term=0
subagentSpawn      bundle=0   chat=0   term=0
SubagentEnd        bundle=0   chat=0   term=0
SubAgentEnd        bundle=0   chat=0   term=0
```

Note what the two Claude-Code-shaped spellings do: `SubagentStop` — the name
most people arrive with — is **0 in all three files**. The four non-zero rows
are classified next.

**Command** (classifying every non-zero hit; this is the part that turns a scary
grep into a settled negative):

```bash
grep -boF 'SubAgentStart' "$bundle"
grep -boF 'SubAgentComplete' "$bundle"
head -c $((845055+500)) "$bundle" | tail -c 700
head -c $((19539647+120)) "$bundle" | tail -c 320
head -c $((19796131+60)) "$bundle" | tail -c 120
grep -aboF 'SubagentSpawn' "$rustchat"
head -c $((396387091+40)) "$rustchat" | tail -c 200 | tr -c '[:print:]\n' '.'
```

**Output at capture:**

```
833056:SubAgentStart
845055:SubAgentStart
852337:SubAgentStart
```

```
833084:SubAgentComplete
845418:SubAgentComplete
852371:SubAgentComplete
19794241:SubAgentComplete
19796131:SubAgentComplete
```

```
 category: external_exports2.enum(["session_start", "session_restore", "session_pause", "session_resume"]),
      context: external_exports2.record(external_exports2.unknown()).optional()
    });
    SubAgentStartPayloadSchema = external_exports2.object({
      type: external_exports2.literal("sub_agent_start"),
      parentExecutionId: external_exports2.string(),
      subSessionId: external_exports2.string(),
      subAgentName: external_exports2.string(),
      prompt: external_exports2.string(),
      explanation: external_exports2.string()
    });
    SubAgentCompletePayloadSchema = external_exports2.object({
      type: external_exports2.literal("sub_agent_complete"),
      parentExecu<<<
```

```
tic ACTIVITY_TYPE_MAP = {
    user: "text",
    assistant: "text",
    tool_call: "toolUse",
    tool_result: "toolResult",
    turn_start: "turnStart",
    turn_end: "turnEnd",
    sub_agent_start: "subAgentStart",
    sub_agent_complete: "subAgentComplete",
    sub_agent_progress: "subAgentProgress",
    steering_inc<<<
```

```
 orphan.subExecutionId }
    }
  };
}
function makeSyntheticSubAgentComplete(orphan, timestamp) {
  return {
    id: `${<<<
```

```
396387091:SubagentSpawn
396762570:SubagentSpawn
```

```
kEvent:(n,t,a,i)=>Lwn(e(),n,t,a,i),handlePipelineStateUpdate:(n,t,a)=>Mwn(e(),n,t,a),prepareKasPermissionRequest:({request:n,toolCallId:t,metadataSubtaskId:a,isSubagentSpawn:i,fallbackTitle:r,fallback<<<
```

All **eleven** non-zero hits are accounted for, none of them a trigger:

| Hits | Where                                    | What it actually is                                                                                                                                          |
| ---: | ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
|    3 | bundle 833056 / 845055 / 852337          | `SubAgentStartPayloadSchema` — one Zod declaration plus two barrel re-export lists                                                                           |
|    5 | bundle 833084 / 845418 / 852371 + 2 more | `SubAgentCompletePayloadSchema` the same way, plus a crash-recovery path (19794241, 19796131) that synthesizes a completion record for a sub-agent left open |
|    1 | bundle 19539647                          | the `ACTIVITY_TYPE_MAP` **value** `"subAgentStart"`, translating a snake_case transcript record to a UI kind                                                 |
|    2 | rustchat 396387091 / 396762570           | the `isSubagentSpawn` boolean on `prepareKasPermissionRequest`, in the embedded-JS region near 396 MB                                                        |

**Positive controls:** this record's load-bearing claim is an absence in three
files, so every zero needs a non-zero neighbour read from the same file by the
same method.

```bash
occ() { { grep -aboF "$1" "$2" || true; } | wc -l; }
for s in SessionStart PostToolUse TRIGGER_ALIAS_TABLE agentSpawn \
         sub_agent_start sub_agent_complete subagentOrchestration toolSearch \
         use_subagent.rs; do
  printf '%-24s bundle=%-4s chat=%-5s term=%s\n' "$s" \
    "$(occ "$s" "$bundle")" "$(occ "$s" "$rustchat")" "$(occ "$s" "$rustterm")"
done
```

```
SessionStart             bundle=71   chat=81    term=17
PostToolUse              bundle=48   chat=7     term=0
TRIGGER_ALIAS_TABLE      bundle=4    chat=0     term=0
agentSpawn               bundle=2    chat=7     term=0
sub_agent_start          bundle=11   chat=0     term=0
sub_agent_complete       bundle=9    chat=0     term=0
subagentOrchestration    bundle=4    chat=1     term=0
toolSearch               bundle=33   chat=15    term=0
use_subagent.rs          bundle=0    chat=6     term=0
```

Read the controls per column. **bundle:** `SessionStart` 71, `PostToolUse` 48,
`TRIGGER_ALIAS_TABLE` 4, `sub_agent_start` 11 — the hook vocabulary and the
subagent journaling are both plainly readable, so the zeros are real. **chat:**
`SessionStart` 81, `toolSearch` 15, `use_subagent.rs` 6 — the 555 MB binary is
being read. **term:** `SessionStart` 17 is the only control that fires;
`PostToolUse` and `TRIGGER_ALIAS_TABLE` are 0 there, which is itself the finding
that `kiro-cli-term` carries essentially no hook machinery — so treat `term`
zeros as weakly controlled and lean on `SessionStart` alone. If a re-run shows
every control collapsing toward 0, the greps have lost the files, not discovered
a removal.

**Notes:** the practical consequence is that a hook file naming `SubagentStop`
does not error at any surface a user sees — it is dropped at load with a
`logger.warn` and a `hooks.unknownTrigger` telemetry count (R-hooks-1), so the
symptom is a hook that never fires and no message explaining why. Also note
`agentSpawn` = 7 in the Rust chat binary versus 2 in the bundle: the CLI alias
predates and outlives the KAS table, which is a reason to expect the name to
keep circulating. Goes stale if a row naming a subagent event appears in the
alias table, or if any of the four classified hits moves from a payload schema
into a trigger position.

---

## R-hooks-3 — Establish that ONE boolean short-circuits the prompt-hook and agent-stop graph nodes, which are wired into the graph a dispatched sub-agent runs

**Establishes:** `execution.skipHooks` is the whole gate. Each agent graph has
exactly **two** hook nodes — a prompt-hooks node and an agent-stop node — and
each begins with the same three-line early return on that boolean. Both nodes
are `addNode`-ed and edge-wired in **both** graphs, including the graph a
dispatched sub-agent runs, so under `skipHooks` they are **present and skipped,
not absent**.

**Why it matters:** a skipped node is a configuration outcome, not a structural
one, which is what makes R-hooks-5's one-line unlock possible at all. It also
fixes the failure shape: the node runs, returns state unchanged, and reports
nothing — so a suppressed `SessionStart` hook is indistinguishable at runtime
from a hook that is not installed, from an untrusted workspace, and from a hook
whose trigger name was dropped at load (R-hooks-2). Four distinct causes, one
symptom.

**Semantic anchor:** search for the execution's hook-suppression boolean. Every
occurrence of it read off an execution should classify as either one of the
graph nodes' opening guards or a source comment about them. The prompt-hooks
node computes a first-turn flag from the presence of previous messages and
delegates to a shared user-hook node with the trigger list that flag selects
(R-hooks-4); the agent-stop node instead delegates with a fixed single-element
stop trigger list and latches an "already executed" flag so a restarted graph
does not re-fire it. The agent-stop node lives in a **shared** graph-nodes
module and is reused by both graphs; the prompt-hooks node is **duplicated** per
graph, so the raw count of guarded bodies is three, not two.

**Verified against:** KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29.

**Command:**

```bash
grep -boE 'execution\.skipHooks[^;{]{0,45}' "$bundle"
head -c $((14514608+230)) "$bundle" | tail -c 305
head -c $((17166451+330)) "$bundle" | tail -c 404
head -c $((14071613+330)) "$bundle" | tail -c 396
```

**Output at capture:**

```
14071603:execution.skipHooks)
14514598:execution.skipHooks)
17166441:execution.skipHooks)
18036143:execution.skipHooks. The default sub-agent adapter sets it
```

```
;
}
async function userHookOnPromptsNode2(state2) {
  if (state2.execution.skipHooks) {
    return state2;
  }
  const isFirstTurn = (state2.execution.input.previousMessages?.length ?? 0) === 0;
  return userHookNode(state2, promptHookTriggers(isFirstTurn));
}
function userHookAgentStopRouter2(state2) {
```

```
));
async function userHookOnPromptsNode(state2) {
  if (state2.execution.skipHooks) {
    return state2;
  }
  const input = state2.execution.input;
  const previousMessages = "previousMessages" in input ? input.previousMessages : void 0;
  const isFirstTurn = (previousMessages?.length ?? 0) === 0;
  return userHookNode(state2, promptHookTriggers(isFirstTurn));
}
var postSummarizationRouter2 = create<<<
```

```
sync function agentStopHooksNode(state2) {
  if (state2.execution.skipHooks) {
    return state2;
  }
  if (!state2.onAgentStopHooksExecuted) {
    const newState = await userHookNode(state2, ["agentStop" /* AgentStop */]);
    const mergedState = { ...state2, ...newState, onAgentStopHooksExecuted: true };
    mergedState.execution.state = mergedState;
    return mergedState;
  } else {
    st<<<
```

Both early returns are quoted verbatim above, and all three guard bodies are
byte-identical (fenced without a language so no formatter can reflow them):

```
  if (state2.execution.skipHooks) {
    return state2;
  }
```

**Command** (both nodes are wired into both graphs — the "present and skipped"
half):

```bash
grep -boE 'addNode\("USER_HOOK[A-Z_]*", [A-Za-z0-9_.]*' "$bundle"
grep -boE '(addEdge|addConditionalEdges)\([^)]{0,70}USER_HOOK[A-Z_]*' "$bundle"
grep -boE 'graph3 = graph3\.(addNode|addEdge|addConditionalEdges)\("?[A-Z_]*' "$bundle"
```

**Output at capture:**

```
14517284:addNode("USER_HOOK_ON_PROMPTS", userHookOnPromptsNode2
14517665:addNode("USER_HOOK_AGENT_STOP", agentStopHooksNode
17165986:addNode("USER_HOOK_ON_PROMPTS", userHookOnPromptsNode
17173428:addNode("USER_HOOK_AGENT_STOP", agentStopHooksNode
```

```
14517361:addEdge(START, "USER_HOOK_ON_PROMPTS
14517421:addEdge("USER_HOOK_ON_PROMPTS
14518035:addConditionalEdges("USER_HOOK_AGENT_STOP
17165930:addEdge(START, "USER_HOOK_ON_PROMPTS
17166058:addEdge("USER_HOOK_ON_PROMPTS
17173497:addConditionalEdges("USER_HOOK_AGENT_STOP
```

```
14516594:graph3 = graph3.addNode(
14517268:graph3 = graph3.addNode("USER_HOOK_ON_PROMPTS
14517345:graph3 = graph3.addEdge(START
14517405:graph3 = graph3.addEdge("USER_HOOK_ON_PROMPTS
14517474:graph3 = graph3.addNode("REMIND_RESPONSE
14517585:graph3 = graph3.addEdge("REMIND_RESPONSE
14517649:graph3 = graph3.addNode("USER_HOOK_AGENT_STOP
14518019:graph3 = graph3.addConditionalEdges("USER_HOOK_AGENT_STOP
```

`graph3` is the custom-agent graph (`src/graphs/custom-agent-graph.ts`), and
`START` flows straight into `USER_HOOK_ON_PROMPTS`.

**Command** (and that IS the graph a dispatched sub-agent runs — see R-hooks-5
for the two adapters that both build a `CustomAgentExecutionDefinition`):

```bash
grep -boE 'CustomAgentGraph[^;,)]{0,40}' "$bundle"
head -c $((14523843+180)) "$bundle" | tail -c 250
```

**Output at capture:**

```
14515020:CustomAgentGraphState
14515077:CustomAgentGraph
14515569:CustomAgentGraph"
14515620:CustomAgentGraphState = Annotation.Root({
14516566:CustomAgentGraphState
14518133:CustomAgentGraph = graph3.compile(
14523843:CustomAgentGraph.invoke(await execution.getState(
17245757:CustomAgentGraph
18036614:CustomAgentGraph
19315768:CustomAgentGraph and take their general-purpose tools fr
```

```
  return [msg];
      }
      async invoke(execution) {
        await CustomAgentGraph.invoke(await execution.getState(), {
          recursionLimit: CUSTOM_AGENT_GRAPH_TRANSITION_LIMIT,
          signal: execution.abortController.signal
        });
```

**Positive controls:** the "exactly two nodes" claim bounds a count, so the
denominators are stated rather than controlled; the absence claim it depends on
— that nothing gates hooks on depth or execution identity — is R-nesting-3 in
`concurrency-and-nesting.md`, which carries those controls (`isSubExecution` /
`isRootSession` / `isSubAgent` all 0 beside seven non-zero controls).

**Command** (the denominator — every occurrence of the string, classified, with
the unrelated same-prefix identifier subtracted):

```bash
occ() { { grep -boF "$1" "$bundle" || true; } | wc -l; }
printf 'skipHooks                  %s\n' "$(occ skipHooks)"
printf 'skipHooksForNextToolCall   %s\n' "$(occ skipHooksForNextToolCall)"
printf 'execution.skipHooks        %s\n' "$(occ execution.skipHooks)"
grep -boF 'skipHooks' "$bundle" | while IFS=: read -r o _; do
  ctx=$(head -c $((o+34)) "$bundle" | tail -c 46 | tr '\n' ' ')
  case "$ctx" in *skipHooksForNextToolCall*) continue;; esac
  printf '%s  %s\n' "$o" "$ctx"
done
```

**Output at capture:**

```
skipHooks                  29
skipHooksForNextToolCall   8
execution.skipHooks        4
13822959  ride;       skipHooks;       promptContext;
13823655  de,         skipHooks,         promptContext,
13824565         this.skipHooks = skipHooks;         thi
13824577  skipHooks = skipHooks;         this.promptCont
14071613  2.execution.skipHooks) {     return state2;
14514608  2.execution.skipHooks) {     return state2;
16933879  Executor;   skipHooks;   responseNag;   prompt
16942954  e;     this.skipHooks = config2.skipHooks;
16942974  s = config2.skipHooks;     this.responseNag =
16998026  de,         skipHooks: agent.skipHooks,
16998043  ooks: agent.skipHooks,         promptContext:
17166451  2.execution.skipHooks) {     return state2;
17712657  tionId,     skipHooks: opts.skipHooks,     //
17712673  Hooks: opts.skipHooks,     // Steering, reposi
17715087  ges: false, skipHooks: true });   }   extractR
18036068  efinition's skipHooks onto the execution — t
18036153  n execution.skipHooks. The default sub-agent a
18036348  et.         skipHooks: subAgentDefinition.skip
18036378  tDefinition.skipHooks,         // Enforce stru
18036921   split from skipHooks directly above: skipHook
18036947  ctly above: skipHooks is a         // dispatch
```

**Denominators.** 29 total = 8 `skipHooksForNextToolCall` (unrelated, see the
notes) + 21 accounted for below. Note the `printf`-trimmed windows collapse
newlines to spaces, and trailing spaces are stripped in this transcript; the
offsets are what identify each row.

| Occurrences | Role                                                                                             |
| ----------: | ------------------------------------------------------------------------------------------------ |
|       **3** | **the graph-node guards** — 14071613 (agent-stop, shared), 14514608 + 17166451 (prompt hooks)    |
|           2 | class field declarations — 13822959 (execution definition), 16933879 (agent execution)           |
|           1 | constructor destructure parameter — 13823655                                                     |
|           4 | the two field assignments, LHS + RHS each — 13824565/13824577 and 16942954/16942974              |
|           2 | top-level execution wire, LHS + RHS — 16998026/16998043                                          |
|           2 | definition-builder wire, LHS + RHS — 17712657/17712673                                           |
|           1 | **`skipHooks: true` in `DefaultSubAgentAdapter`** — 17715087, the only place it is ever set true |
|           2 | child-execution wire, LHS + RHS — 18036348/18036378                                              |
|           4 | source comments — 18036068, 18036153, 18036921, 18036947                                         |

`execution.skipHooks` is 4: the three node guards plus one of those comments.
And `addNode("USER_HOOK…` is 4: two graphs x two hook nodes.

**Notes.** Two corrections worth carrying:

- "**Exactly two graph nodes**" is right **per graph** and wrong as a count of
  guarded function bodies: there are **three**, because the prompt-hooks node is
  written twice (once per graph) while the agent-stop node is shared. State it
  as "two node roles, three bodies" and both halves stay true.
- `skipHooks` and `skipHooksForNextToolCall` are unrelated despite the shared
  prefix. The latter is a per-turn suppression list keyed by tool id, living in
  the ~19.8 MB tool-hook bridge region; it is not this gate and does not appear
  on the execution.

Goes stale if a graph gains or loses a hook node, if the guard moves from the
node body into an edge/router (which would make it structural instead of
short-circuiting), or if either node stops being wired in the custom-agent
graph.

---

## R-hooks-4 — Establish the one-shot-vs-per-turn trigger split, and that a dispatched sub-execution always takes the first-turn branch

**Establishes:** one three-line helper decides the prompt-hook trigger list. On
a first turn it returns **`[sessionStart, promptSubmit]`**; on every later turn
it returns **`[promptSubmit]`**. "First turn" is `previousMessages` being absent
or empty. The dispatch context hard-codes `previousMessages: void 0`, so a
dispatched sub-execution **always** evaluates as a first turn and — once
un-gated — fires **both** `SessionStart` and `UserPromptSubmit` on its single
prompt-hook pass.

**Why it matters:** it settles which trigger to use for what. `SessionStart` is
a one-shot injection point and `UserPromptSubmit` is a per-turn one **in a
long-running session**; inside a dispatched worker the distinction collapses,
because the worker's graph runs once and takes the first-turn branch, so both
fire and either is a usable injection point. A design that installs only
`UserPromptSubmit` because it wants "every turn" gets exactly one firing per
worker, which is the same thing `SessionStart` would have given it.

**Semantic anchor:** in the shared user-hook-node module, immediately after a
local `assertNever` helper, a pure function takes a boolean and returns a one-
or two-element array of camelCase internal trigger values, with `promptSubmit`
in both arms and `sessionStart` prepended only in the first-turn arm. Its three
call sites are its own definition and the two prompt-hook graph nodes of
R-hooks-3, each of which passes a locally computed "no previous messages" flag.
The array is consumed by a loop that fires the triggers in order and bails early
if one asks to restart the graph.

**Verified against:** KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29.

**Command:**

```bash
grep -boE 'promptHookTriggers[^;{]{0,45}' "$bundle"
head -c $((14062561+300)) "$bundle" | tail -c 315
```

**Output at capture:**

```
14062658:promptHookTriggers(isFirstTurn)
14514758:promptHookTriggers(isFirstTurn))
17166708:promptHookTriggers(isFirstTurn))
```

```
/user-hook-node.ts
function assertNever4(x2) {
  throw new Error(`Unexpected value: ${String(x2)}`);
}
function promptHookTriggers(isFirstTurn) {
  return isFirstTurn ? ["sessionStart" /* SessionStart */, "promptSubmit" /* UserPrompt */] : ["promptSubmit" /* UserPrompt */];
}
async function _userHookNode(state2, t<<<
```

Verbatim, the whole rule:

```
function promptHookTriggers(isFirstTurn) {
  return isFirstTurn ? ["sessionStart" /* SessionStart */, "promptSubmit" /* UserPrompt */] : ["promptSubmit" /* UserPrompt */];
}
```

Three occurrences, all accounted for: the definition plus the two prompt-hook
nodes quoted in R-hooks-3 (14514758 and 17166708 sit inside those two node
bodies).

**Command** (the dispatch context pins the first-turn branch):

```bash
grep -boE 'previousMessages: (void 0|ctx\.previousMessages)' "$bundle"
head -c $((18031029+80)) "$bundle" | tail -c 700
```

**Output at capture:**

```
17712396:previousMessages: ctx.previousMessages
18030796:previousMessages: void 0
```

```
2.execution.autonomyMode,
        workspace: state2.execution.workspace,
        agentContext: state2.execution.getAgentContext(),
        agentMode: customAgentDefinition.agentMode,
        executionId: subExecutionId,
        steering: state2.execution.steering,
        repositories: state2.execution.repositories,
        knowledgeListing: state2.execution.knowledgeListing,
        previousMessages: void 0,
        specWorkflow: state2.execution.promptContext?.specWorkflow,
        specSkipClarificationEnabled: state2.execution.promptContext?.specSkipClarificationEnabled ?? true
      };
      const adapter2 = selectAdapter(customAgentDefinition);
      const subAgentDefinition = await ada<<<
```

The `ctx.previousMessages` read at 17712396 is inside
`buildDispatchedCustomAgentDefinition` and is reached only when the adapter opts
in (R-hooks-5) — but `ctx.previousMessages` is the `void 0` above, so both
branches yield an empty previous-message list and `isFirstTurn` is `true` either
way.

**Command** (the loop that fires the list, and the camelCase-to-canonical seam):

```bash
o=$(grep -boF 'function _userHookNode' "$bundle" | cut -d: -f1)
head -c $((o+330)) "$bundle" | tail -c 360
head -c $((13926606+180)) "$bundle" | tail -c 200
```

**Output at capture:**

```
t" /* UserPrompt */];
}
async function _userHookNode(state2, triggers) {
  let updatedState = state2;
  for (const trigger of triggers) {
    try {
      const result = await handleTrigger(updatedState, trigger);
      if ("shouldRestartGraph" in result && result.shouldRestartGraph) {
        return result;
      }
      updatedState = result;
    } catch {
```

```
ks/actions/input.ts
function buildHookInput(ctx) {
  const common = {
    session_id: ctx.sessionId,
    hook_event_name: canonicalTriggerName(ctx.trigger),
    cwd: ctx.cwd
  };
  switch (ctx.trigger<<<
```

So the graph speaks `sessionStart` / `promptSubmit` / `agentStop` while the
hook's stdin receives the canonical PascalCase `hook_event_name` from R-hooks-1.

**Positive controls:** not required — every claim here is a presence.

**Notes:** ordering is load-bearing and is fixed by the array literal —
`sessionStart` fires **before** `promptSubmit`, in one sequential loop, and a
trigger that asks to restart the graph aborts the remainder of the list. The
`isFirstTurn` derivation differs cosmetically between the two graphs (one reads
`input.previousMessages` directly, the other guards with
`"previousMessages" in input`) but both reduce to `(len ?? 0) === 0`. Goes stale
if the helper gains a third arm, if `sessionStart` and `promptSubmit` swap
order, or if the dispatch context starts forwarding real previous messages —
that last one would make a dispatched worker stop taking the first-turn branch
and would silently drop `SessionStart` from un-gated workers.

---

## R-hooks-5 — Establish the unlock: an optional agent-profile field picks the dispatch adapter, and only one of the two adapters sets the skip flag

**Establishes:** `dispatchKind` — an **optional** agent-profile field typed
`z.enum(["sub-agent", "custom-agent", "spec"]).optional()` in both the markdown
front-matter schema and the JSON agent-file schema — selects the dispatch
adapter. `DefaultSubAgentAdapter` builds its definition with
**`skipHooks: true`**; `CustomAgentAdapter` **omits the option entirely**, so
the field is `undefined`, falsy, and the two gated nodes of R-hooks-3 run. Unset
`dispatchKind` defaults to `"sub-agent"`, hence the skip. **One front-matter
line turns prompt and stop hooks on inside dispatched workers.**

**Why it matters:** this is the most actionable finding in the group. It
converts "hooks don't fire in subagents" from a platform limitation into a
default, and the override is declarative, per-profile, and needs no branching
inside the hook script. It also means level-scoping is a **configuration** fact:
give a worker role its own profile with `dispatchKind: custom-agent` and its
hooks fire, while every other dispatched role keeps the default silence.

**Semantic anchor:** a `select-adapter` module reads a dispatch-kind field off
the resolved agent definition, defaulting it to the sub-agent value with `??`,
then branches to one of three adapter classes and logs the choice. Two of those
adapters are thin wrappers over the same definition builder and differ **only**
in the options object they pass: the custom-agent one passes a single option
asking for previous messages to be included; the default sub-agent one asks for
them to be excluded **and** additionally passes the hook-skip flag. The builder
copies that flag onto the definition, and the sub-agent dispatch site copies it
from the definition onto the child execution — with a four-line source comment
saying exactly that. The receiving execution class assigns the field with **no
default**, so absent means falsy. The third adapter (spec) does not use that
builder at all — it constructs a spec-generation definition instead — and the
source comment on the child-execution wire says outright that both non-default
kinds leave the flag unset.

**Verified against:** KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29.

**Command** (the selector):

```bash
grep -boE 'selectAdapter[^;{]{0,40}' "$bundle"
head -c $((17717141+470)) "$bundle" | tail -c 470
```

**Output at capture:**

```
17717199:selectAdapter(definition)
18031029:selectAdapter(customAgentDefinition)
```

```
// src/tools/subagent-dispatch/select-adapter.ts
function selectAdapter(definition) {
  const dispatchKind = definition.dispatchKind ?? "sub-agent";
  let adapter2;
  if (dispatchKind === "custom-agent") {
    adapter2 = new CustomAgentAdapter();
  } else if (dispatchKind === "spec") {
    adapter2 = new SpecAdapter();
  } else {
    adapter2 = new DefaultSubAgentAdapter();
  }
  logger.debug("dispatch.adapter.selected", { agentId: definition.id, dispatchKind });
```

Exactly one production call site (18031029, in the invoke-subagent handler); the
other offset is the definition's own parameter list.

**Command** (both adapter bodies, in one window, so the asymmetry is not
assembled from two reads):

```bash
head -c $((17714300+840)) "$bundle" | tail -c 840
grep -boE 'buildDispatchedCustomAgentDefinition\(ctx, \{[^}]*\}\)' "$bundle"
```

**Output at capture:**

```
// src/tools/subagent-dispatch/custom-agent-adapter.ts
var CustomAgentAdapter = class {
  built = false;
  async buildDefinition(ctx) {
    this.built = true;
    return buildDispatchedCustomAgentDefinition(ctx, { includePreviousMessages: true });
  }
  extractResult(execution) {
    if (!this.built) {
      throw new Error("extractResult called before buildDefinition -- this is a programmer error");
    }
    const { response, files } = extractSubagentResponse(execution);
    return { kind: "custom-agent", response, files };
  }
};

// src/tools/subagent-dispatch/sub-agent-adapter.ts
var DefaultSubAgentAdapter = class {
  built = false;
  async buildDefinition(ctx) {
    this.built = true;
    return buildDispatchedCustomAgentDefinition(ctx, { includePreviousMessages: false, skipHooks: true });
  }
  extractResult(execution) {<<<
```

```
17714470:buildDispatchedCustomAgentDefinition(ctx, { includePreviousMessages: true })
17715011:buildDispatchedCustomAgentDefinition(ctx, { includePreviousMessages: false, skipHooks: true })
```

The whole difference, side by side and verbatim:

```
// CustomAgentAdapter      — no skipHooks => undefined => falsy => HOOKS RUN
buildDispatchedCustomAgentDefinition(ctx, { includePreviousMessages: true })
// DefaultSubAgentAdapter  — skipHooks: true => the two nodes early-return
buildDispatchedCustomAgentDefinition(ctx, { includePreviousMessages: false, skipHooks: true })
```

Two call sites of that builder, total — so the pair above is the entire
decision.

**Command** (the third adapter, for completeness — it never reaches that
builder):

```bash
head -c $((17716008+340)) "$bundle" | tail -c 380
```

**Output at capture:**

```
atch/spec-adapter.ts
init_logger();
var SpecAdapter = class {
  definition;
  // eslint-disable-next-line @typescript-eslint/require-await -- interface requires Promise for other adapters' lazy imports
  async buildDefinition(ctx) {
    const agentMode = ctx.specWorkflow === "quick" ? "quick-spec" : "spec";
    const params = buildSpecGenerationInput({
      prompt: ctx.prompt,<<<
```

**Command** (the enum, in both schemas, with its doc comment):

```bash
grep -boE 'dispatchKind: external_exports2\.enum\(\[[^]]*\]\)\.optional\(\)' "$bundle"
head -c $((17210272+130)) "$bundle" | tail -c 300
grep -boE '[A-Za-z0-9_]+Schema[0-9]? = (external_exports2|CustomAgentFileFrontMatterSchema)' "$bundle" \
  | awk -F: '$1>17205000 && $1<17216000'
grep -boE 'dispatchKind: (result|data2|parsed2)[A-Za-z.]*' "$bundle"
```

**Output at capture:**

```
17210272:dispatchKind: external_exports2.enum(["sub-agent", "custom-agent", "spec"]).optional()
17212889:dispatchKind: external_exports2.enum(["sub-agent", "custom-agent", "spec"]).optional()
```

```
n switching to this agent */
  welcomeMessage: external_exports2.string().optional(),
  /** Optional: controls which dispatch adapter handles this agent's execution */
  dispatchKind: external_exports2.enum(["sub-agent", "custom-agent", "spec"]).optional(),
  /** Optional: hooks embedded inline in t<<<
```

```
17206983:PermissionsPolicySchema = external_exports2
17207552:AgentResourcesSchema = external_exports2
17207977:CustomAgentFileFrontMatterSchema = external_exports2
17210523:JsonAgentFileSchema = external_exports2
17215781:ClientAgentPermissionsPolicySchema = external_exports2
```

```
17223221:dispatchKind: result.frontMatter.dispatchKind
17224771:dispatchKind: data2.dispatchKind
17231205:dispatchKind: parsed2.frontMatter.dispatchKind
```

So 17210272 is inside `CustomAgentFileFrontMatterSchema` (the `.md` front
matter) and 17212889 inside `JsonAgentFileSchema` (the `.json` agent file) —
identical enums, and three parse paths read the field straight through to the
definition: two front-matter, one JSON.

**Command** (the flag's path from adapter option to child execution, and the
absent default):

```bash
head -c $((17712657+30)) "$bundle" | tail -c 36
head -c $((18036045+390)) "$bundle" | tail -c 400
head -c $((16942949+38)) "$bundle" | tail -c 38
```

**Output at capture:**

```
,
    skipHooks: opts.skipHooks,
```

```
          // Carry the definition's skipHooks onto the execution — the graph's hook
        // nodes gate on execution.skipHooks. The default sub-agent adapter sets it
        // (dispatched sub-agents don't fire the user's session/prompt/stop hooks);
        // custom-agent/spec dispatch leave it unset.
        skipHooks: subAgentDefinition.skipHooks,
        // Enforce structured handoff for agen<<<
```

```
this.skipHooks = config2.skipHooks;
```

The vendor's own comment states the behavior and the intent, which is as close
to documentation as this mechanism has. Note the assignment carries **no**
`?? false` — unset stays `undefined`, which is exactly what makes omitting the
option sufficient.

**Positive controls:** not required — every claim here is a presence. The
related absence (nothing else gates the nodes) is R-hooks-3 plus R-nesting-3 in
`concurrency-and-nesting.md`.

**Notes:** three caveats before treating this as a supported switch.

- `dispatchKind` is **undocumented** and is the one finding in this group that
  is a hair's breadth from being _config_ rather than _evidence_: the moment a
  typed agent surface generates it, a stale enum produces a broken module rather
  than a stale note, and it belongs with extracted option enums instead of here.
- Setting `dispatchKind: custom-agent` changes more than hooks. The same adapter
  choice also flips `includePreviousMessages` and changes the result-extraction
  shape (`kind: "custom-agent"`), so it is not a hooks-only toggle.
- The switch does nothing without the other preconditions: hook execution
  requires workspace trust, and a hook whose trigger name is not in R-hooks-1's
  table is dropped at load. All three failures look identical — silence.

Goes stale if a fourth `dispatchKind` value appears, if `CustomAgentAdapter`
starts passing `skipHooks`, if the `??` default changes, or if the execution
class starts defaulting the field to `false`.

---

## R-hooks-6 — Establish that tool-use and file hooks are ungated: their call sites carry no skip check at all

**Establishes:** the `PreToolUse`, `PostToolUse` and `PostFile*` paths never
consult `skipHooks`, depth, or execution identity. Each reads the hook registry
off `state2.execution.sessionServices.hooks` and fires; the only guard on any of
them is a "are any hooks of this kind installed" existence test. Across the
**27700-byte** region holding all three call sites, `skipHooks`,
`subExecutionDepth`, `isSubExecution` and `dispatchKind` occur **zero** times.

**Why it matters:** it splits the hook surface in two along a line nobody
documents. Tool and file hooks work inside a dispatched worker **as workers
exist today**, with no profile change and no `dispatchKind` (R-hooks-5) — which
makes observation-only uses (journaling a worker's tool calls and file writes)
available immediately, while injection-shaped uses (`SessionStart` /
`UserPromptSubmit` / `Stop`) need the unlock. The reason is structural, not a
special case: these paths simply do not route through the two gated graph nodes.

**Semantic anchor:** the eight reads of the session hook registry off an
execution split four/four. Four sit inside the shared user-hook node layer —
extract hooks, run stop hooks, read precomputed results, execute a hook action —
and are reachable only through the two guarded nodes of R-hooks-3. The other
four are on the tool-execution wrapper: a pre-tool method that grabs the
registry **into a local** and returns early if no pre-tool hooks are registered
(so its actual execute call goes through the local and does not appear in a
`sessionServices.hooks.` grep — that is the fourth row, the bare registry read);
the existence test itself; a post-tool call made inline on the result path after
a tool completes; and a post-file method that awaits the file executor inside a
try/catch and emits a per-hook invocation event. None of them tests anything
about the execution.

**Verified against:** KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29.

**Command** (the split, then the three ungated call sites):

```bash
grep -boE 'sessionServices\.hooks[.A-Za-z]*' "$bundle"
grep -boE '(hooks|sessionServices\.hooks)\.executePreToolUseHooks' "$bundle"
head -c $((17094392+300)) "$bundle" | tail -c 322
head -c $((17100877+520)) "$bundle" | tail -c 800
head -c $((17121165+250)) "$bundle" | tail -c 280
```

**Output at capture:**

```
14064268:sessionServices.hooks.extractHooks
14065383:sessionServices.hooks.runStopHooks
14066463:sessionServices.hooks.extractPrecomputedResults
14068914:sessionServices.hooks.executeHookAction
17094462:sessionServices.hooks
17099781:sessionServices.hooks.hasPreToolUseHooks
17100855:sessionServices.hooks.executePostToolUseHooks
17121280:sessionServices.hooks.executePostFileHooks
```

```
17094671:hooks.executePreToolUseHooks
```

```
rcept.)
   */
  async runPreToolUseHooks(state2, args) {
    const hooks = state2.execution.sessionServices.hooks;
    if (!hooks.hasPreToolUseHooks()) {
      return { state: state2 };
    }
    try {
      logger.debug("hooks.preToolUse.invoke", { toolId: this.id });
      const hookResult = await hooks.executePreToolU<<<
```

```
== "toolUse" || e5.type === "toolUseResponse") && e5.id === toolUseId);
          const toolArgs = toolUseEntry?.type === "toolUse" || toolUseEntry?.type === "toolUseResponse" ? toolUseEntry.args : {};
          const postHookResult = await state2.execution.sessionServices.hooks.executePostToolUseHooks(
            this.id,
            this.tags,
            toolArgs,
            toolResult,
            toolSuccess,
            resultState
          );
          resultState = postHookResult.state;
          if (postHookResult.hookMessage) {
            logger.debug("hooks.postToolUse.hasMessage", { toolId: this.id });
            const postToolMessage = 'PostToolUse hooks have additional instructions after "' + this.id + '" completed.\n\nTool result: ' + (toolSuccess ? "Success" : "Failed"<<<
```

```
rmed the write.
   */
  async firePostFileHooks(state2, filePath, eventType) {
    let outcome;
    try {
      outcome = await state2.execution.sessionServices.hooks.executePostFileHooks(filePath, eventType);
    } catch (err) {
      logger.debug("hooks.postFile.error", { fileP<<<
```

The pre-tool guard is quoted in full, and it is the only guard on that path:

```
    const hooks = state2.execution.sessionServices.hooks;
    if (!hooks.hasPreToolUseHooks()) {
      return { state: state2 };
    }
```

The post-tool and post-file sites have no guard at all beyond the registry
returning nothing to do.

**Command** (region-scoped absence, which is stronger than eyeballing three
windows — it shows no skip check anywhere in the enclosing code, not merely at
the lines shown):

```bash
seg() { head -c "$2" "$bundle" | tail -c $(( $2 - $1 )); }
echo "== region A: tool + file hook call sites, bytes 17094300-17122000 (27700 B) =="
for s in skipHooks subExecutionDepth isSubExecution dispatchKind sessionServices.hooks hasPreToolUseHooks; do
  printf '  %-24s %s\n' "$s" "$( { seg 17094300 17122000 | grep -boF "$s" || true; } | wc -l )"
done
echo "== region B: hook trigger/executor layer, bytes 13960000-13990000 (30000 B) =="
for s in skipHooks subExecutionDepth isSubExecution dispatchKind PreToolUse PostFileCreate; do
  printf '  %-24s %s\n' "$s" "$( { seg 13960000 13990000 | grep -boF "$s" || true; } | wc -l )"
done
echo "== region C: hooks node layer, bytes 14060000-14075000 (15000 B) =="
for s in skipHooks subExecutionDepth hasPreToolUseHooks executePostFileHooks agentStopHooksNode; do
  printf '  %-24s %s\n' "$s" "$( { seg 14060000 14075000 | grep -boF "$s" || true; } | wc -l )"
done
```

**Output at capture:**

```
== region A: tool + file hook call sites, bytes 17094300-17122000 (27700 B) ==
  skipHooks                0
  subExecutionDepth        0
  isSubExecution           0
  dispatchKind             0
  sessionServices.hooks    4
  hasPreToolUseHooks       2
== region B: hook trigger/executor layer, bytes 13960000-13990000 (30000 B) ==
  skipHooks                0
  subExecutionDepth        0
  isSubExecution           0
  dispatchKind             0
  PreToolUse               10
  PostFileCreate           6
== region C: hooks node layer, bytes 14060000-14075000 (15000 B) ==
  skipHooks                1
  subExecutionDepth        0
  hasPreToolUseHooks       1
  executePostFileHooks     1
  agentStopHooksNode       1
```

**Positive controls:** the load-bearing claim is an absence inside three named
byte ranges, so each range must be shown to be readable by the same method that
reported the zeros. **Region A** returns 4 and 2 for the very identifiers whose
call sites are being examined. **Region B** returns 10 `PreToolUse` and 6
`PostFileCreate` — the executor layer is present and greppable, and still has no
skip check. **Region C** is the control range in the other direction: it returns
`skipHooks` **1**, which is precisely the `agentStopHooksNode` guard of
R-hooks-3 falling inside those bytes — i.e. the same one-liner probe that
reports 0 in regions A and B reports 1 where a guard genuinely exists. That is
what separates "no guard here" from "my probe is broken".

The whole-bundle controls for these strings — `skipHooks` 29,
`execution.skipHooks` 4, `dispatchKind` 16, `runPreToolUseHooks` 4,
`executePostToolUseHooks` 2, `firePostFileHooks` 3, `sessionServices` 40 — are
recorded in R-hooks-3 and R-hooks-5; all non-zero, so the strings are findable
in this bundle and the regional zeros are regional.

**Notes:** region C's `subExecutionDepth 0` is worth reading alongside
R-nesting-3 in `concurrency-and-nesting.md`, which classifies all 6 occurrences
of that field bundle-wide and finds none of them anywhere near a hook path — the
regional zero and the global classification agree. This record is **static
only**: it establishes that no code gates these paths, not that a hook
observably fires inside a live sub-execution — the recorded machine-state
evidence for the gated triggers used only gated-trigger hook documents, so it
says nothing about tool hooks either way. That remains a live-session question.
Goes stale if a skip check appears at any of the four ungated call sites, or if
the tool wrapper starts routing tool hooks through the shared user-hook node
(which would put them behind the gate).

---

## R-hooks-7 — Establish that the child shares the parent's session services, workspace and chat-session id by reference

**Establishes:** the sub-agent execution is constructed with
`sessionServices: state2.execution.sessionServices` — the **same object**, not a
copy or a rebuild — and the dispatch context likewise forwards
`workspace: state2.execution.workspace` and
`chatSessionId: state2.execution.chatSessionId`. The hook binding on those
services is built **once per session** from `workspacePaths[0]` as its `cwd`, so
a child fires hooks from the same registry, in the same working directory, under
the same `session_id`.

**Why it matters:** three consequences, all design-relevant. Hooks installed for
the session are automatically visible to every descendant — nothing needs
propagating, and there is no per-child registry to configure.
`${WORKSPACE_ROOT}` and the hook's `cwd` are the parent's, so a worker's hook
script and the root's hook script resolve relative paths identically, which is
what makes a shared on-disk queue a viable channel. And because `session_id` and
`cwd` are identical at every level, **a hook script cannot tell which level it
is running at** — the payload carries no agent name, no execution id and no
depth. Level-scoping is therefore a profile question (R-hooks-5), never a
runtime branch inside the hook.

**Semantic anchor:** the invoke-subagent handler, having passed the depth gate,
constructs the child execution and populates most fields from the resolved
sub-agent definition, but takes three **from the parent's own execution
object**: the session services bag, the prompt context, and the abort signal.
Separately, the dispatch context assembled just above it copies the parent's
workspace, agent context, steering, repositories, knowledge listing and chat
session id. On the services side, a session-scoped builder method — documented
as building "this session's hook binding", reloaded per session start so edits
to the workspace hook files apply without a restart — closes a single working
directory and session id over the executors and hands back one hooks object;
that object is what the child receives. Finally, the hook stdin builder puts
only session id, canonical trigger name and that working directory in its common
block, and none of its per-trigger arms adds anything naming the agent, the
execution, or the depth.

**Verified against:** KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29.

**Command:**

```bash
grep -boF 'sessionServices:' "$bundle"
grep -boE 'sessionServices: [A-Za-z0-9_.]{0,45}' "$bundle"
head -c $((18038018+240)) "$bundle" | tail -c 300
grep -boE '(chatSessionId|workspace): state2\.execution\.[A-Za-z()]*' "$bundle" \
  | awk -F: '$1>18030000 && $1<18039000'
```

**Output at capture:**

```
16998335:sessionServices:
17392409:sessionServices:
18038018:sessionServices:
```

```
16998335:sessionServices: services
17392409:sessionServices: services
18038018:sessionServices: state2.execution.sessionServices
```

```
ssage: subAgentDefinition.hideSimulatedTurnMessage,
        sessionServices: state2.execution.sessionServices,
        promptContext: state2.execution.promptContext,
        signal: state2.execution.abortController.signal,
        subExecutionDepth: currentDepth + 1,
        agentName: subagentId
  <<<
```

```
18030335:chatSessionId: state2.execution.chatSessionId
18030443:workspace: state2.execution.workspace
```

Three `sessionServices:` occurrences in the whole bundle, and the fixed-string
count agrees with the regex — so the regex is not hiding a fourth. Two are
top-level session paths passing a freshly built `services` bag; the **only**
sub-agent one passes the parent's object through. There is no other path by
which a child could get a different registry.

**Command** (one hook binding per session, with `cwd` fixed at build time):

```bash
grep -boE 'this\.sessionServices[^;]{0,40}' "$bundle"
grep -boE 'new SessionHooks\(\{' "$bundle"
head -c $((20502103+230)) "$bundle" | tail -c 250
```

**Output at capture:**

```
16943163:this.sessionServices = config2.sessionServices
16956609:this.sessionServices.origin
16971936:this.sessionServices.origin)
16972433:this.sessionServices.origin)
```

```
20295925:new SessionHooks({
20296254:new SessionHooks({
20502975:new SessionHooks({
```

```
ed binding.
   */
  async buildSessionHooks(sessionId, workspacePaths) {
    if (this.v2HooksCache && workspacePaths.length > 0) {
      const cwd = workspacePaths[0];
      const entry = this.v2HooksCache.getOrCreate(workspacePaths);
      await thi<<<
```

`this.sessionServices = config2.sessionServices` — assigned, not cloned, so the
child's field is the parent's object.

**Command** (that `cwd` is what a hook command actually runs in, and what
`${WORKSPACE_ROOT}` expands to):

```bash
head -c $((13939099+250)) "$bundle" | tail -c 700
```

**Output at capture:**

```
         durationMs: 0,
            error: err
          };
        }
        const start = this.deps.clock.now();
        const stdinJson = JSON.stringify(input);
        const timeoutMs = opts.timeoutSeconds === 0 ? void 0 : opts.timeoutSeconds * 1e3;
        const command = hook2.action.command.replace(/\$\{WORKSPACE_ROOT\}/g, opts.cwd);
        try {
          const res = await this.deps.processRunner.spawn({
            command,
            cwd: opts.cwd,
            // Intentionally empty; `IProcessRunner` implementations layer in
            // `process.env`. Hook command input lives on stdin (per the KAS
            // contract) rather than env vars to keep it structured and avoid
```

**Command** (the dependent absence: enumerate every field the hook-stdin builder
can emit, across all of its per-trigger arms, and probe for a level
discriminator):

```bash
seg() { head -c "$2" "$bundle" | tail -c $(( $2 - $1 )); }
seg 13926606 13929038 | grep -boE '^(function|var|async function) [A-Za-z_0-9]+' | head -2
seg 13926606 13929038 | grep -oE '[a-z_]+:' | sed 's/:$//' | sort -u | tr '\n' ' '
echo
for s in agent_name agentName execution_id executionId depth subExecutionDepth parent; do
  printf '  %-20s %s\n' "$s" "$( { seg 13926606 13929038 | grep -boF "$s" || true; } | wc -l )"
done
```

**Output at capture:**

```
0:function buildHookInput
cwd file_path hook_event_name prompt session_id spec_name task_name task_success tool_input tool_name tool_response user_decision
  agent_name           0
  agentName            0
  execution_id         0
  executionId          0
  depth                0
  subExecutionDepth    0
  parent               0
```

**Positive controls.** The by-reference claims are presences and need none. The
absence claim — no level discriminator in a hook payload — is controlled two
ways. Within the probed range, the **12 field names** listed above are the
control: the same extraction that reports 0 for every identity-shaped name
reports a complete, readable field vocabulary, and `head -2` confirms the range
starts at `function buildHookInput` and ends where its module's initializer
begins (so the enumeration covers **all** arms, including the conditionally
spread `user_decision`). Bundle-wide, R-nesting-3 in
`concurrency-and-nesting.md` carries the rest: `isSubExecution` /
`isRootSession` / `isSubAgent` all 0 beside seven non-zero controls, and depth
never leaving the process.

**Notes:** the by-reference sharing is the same three-field block that
`concurrency-and-nesting.md` R-nesting-2 records for a different purpose — a
sub-execution is an in-process object graph, not a separate process, which is
simultaneously why dispatch churn costs no OS processes and why the hook
registry needs no propagation. Two operational riders: the same comment block
shows hook commands are spawned with an **intentionally empty env** (input
arrives on stdin), so a hook cannot be handed context through environment
variables; and `workspacePaths[0]` means a multi-root session pins hooks to the
**first** root. Goes stale if a second sub-agent `sessionServices` assignment
appears, if the child starts receiving a rebuilt services bag, if
`chatSessionId` stops being inherited (which would give hooks a level
discriminator and change R-hooks-5's conclusion about scoping by profile), or if
the hook binding moves from session scope to execution scope.
