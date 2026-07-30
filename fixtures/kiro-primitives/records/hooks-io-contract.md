# Records: hook I/O contract (Kiro CLI v3)

Nine replayable records covering what a hook command actually receives on stdin,
how it is spawned, what its exit code and stdout are allowed to do, where hook
files are loaded from, and the two silent gates that stop a hook running at all.
All captured against KAS
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

At capture `$bundle` was **20752757** bytes. Every command below was executed on
2026-07-29 in a `set -euETo pipefail` shell in which `$bundle` already held the
literal absolute path; substituting that variable name is the only difference
between what is printed here and what was typed. Each "output at capture" block
is the real, unedited output of the command directly above it, with `<<<`
marking where a fixed-size window truncates.

Five conventions carried over from the sibling records, all of which matter:

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
  `grep` is **ugrep 7.5.0**, where `-c -o` counts occurrences instead — the two
  forms disagree. The `|| true` keeps a legitimate zero from failing the
  pipeline.
- **Byte offsets are conveniences, not anchors.** They move on every rebuild.
  The semantic anchor is the durable part.
- **A window's final line is often mid-indentation, and this repo's formatter
  strips trailing whitespace.** So the bytes after the last visible character of
  a `<<<`-marked block are not recoverable from this file. Compare a replay
  against the block with trailing whitespace ignored, or re-narrow the window.
- **The bundle is not identifier-minified.** It is esbuild-bundled but
  pretty-printed, keeps `// src/<path>.ts` section markers, and keeps original
  names and comments. What churns is esbuild's collision suffixes (`state2`,
  `rs2`, `r5`, `parsed2`), so those specific handles are untrustworthy across
  releases.

Two engine-shape facts the whole group depends on, established once here so no
record has to re-derive them:

- The hook implementation lives entirely in the **KAS JS bundle** under
  `src/hooks/`. It is selected at ACP `initialize` time by
  `kiroMeta.hooks.v2 === true`; the alternative binding delegates hook execution
  back over ACP to the client. Everything below describes the **in-process**
  binding (see the measurement below the list).
- The graph does **not** call the per-trigger entry points for the three
  prompt-shaped triggers. `runSessionStartHooks`, `runUserPromptSubmitHooks` and
  `runManualHooks` each occur exactly twice in the bundle — a definition and a
  registration — and **never as a call**. R-hookio-3 is a direct consequence.

That the in-process binding is what a real session gets is a **measurement**,
not an inference: the log line emitted immediately after the `hooks.v2 === true`
check appears in this machine's own session logs.

```bash
find "$HOME/.kiro/logs" -name kiro.log | wc -l
grep -lF 'v2 hooks cache initialized' "$HOME"/.kiro/logs/*/kiro.log | wc -l
grep -hoF '[KiroAgent] v2 hooks cache initialized (hooks load at session start)' \
  "$HOME"/.kiro/logs/*/kiro.log | sort -u
```

```
10
7
[KiroAgent] v2 hooks cache initialized (hooks load at session start)
```

**7 of 10** session logs carry it, and the 3 that do not are byte-identical
2449-byte stubs from sessions that never reached hook initialization — so the
denominator is 7 of 7 sessions that got far enough to choose a binding.

Two deliberate choices in that command, both learned by getting it wrong first:
the glob `"$HOME"/.kiro/logs/*/kiro.log` replaces `grep -r`, whose traversal
order is not stable, and only the **message** is extracted rather than the whole
JSON line — a first draft printed the full record and its timestamp changed on
the next run, which is a recorded output that does not reproduce. This
measurement is machine-state, not bundle-state; a different client (an IDE,
another ACP frontend) may choose the delegating binding, in which case
R-hookio-3 does not apply to it.

---

## R-hookio-1 — Establish the exact stdin payload a hook command receives, per trigger

**Establishes:** one function builds the JSON written to a hook's stdin. Three
fields are common to every trigger (`session_id`, `hook_event_name`, `cwd`) and
the rest are added by an 11-arm switch on the trigger. The per-trigger field
sets are: nothing extra for `SessionStart` and `Manual`; a **conditional**
`user_decision` for `Stop`; `prompt` for `UserPromptSubmit`; `tool_name` +
`tool_input` for `PreToolUse`; those plus `tool_response` for `PostToolUse`;
`spec_name` + `task_name` for `PreTaskExec`; those plus `task_success` for
`PostTaskExec`; and `file_path` for each of `PostFileCreate`, `PostFileSave`,
`PostFileDelete`.

**Why it matters:** this is the entire input contract, and it is narrower than
it looks. There is **no** agent name, **no** execution id, **no** nesting depth,
**no** trigger-matched pattern, and **no** workspace root beyond `cwd`. A hook
script cannot learn which agent or which nesting level it is running under from
its payload — that is a configuration question, not a runtime one. The absent
fields are what make level-aware hook scripts impossible and profile-scoped
hooks necessary.

**Semantic anchor:** in the hooks input module there is a single pure builder
taking a hook-execution context and returning the stdin object. It opens by
composing a `common` object of exactly three snake_case fields from the
context's session id, canonicalized trigger name and cwd, then `switch`es on
`ctx.triggerData.trigger` and returns
`{...common, hook_event_name: "<Literal>", …}` per arm — re-stating
`hook_event_name` as a literal in every arm so the discriminated union narrows.
Field names are snake_case in the payload while the context they are read from
is camelCase, which is the reliable tell that you are looking at the wire format
rather than an internal type. The trigger name is passed through a canonicalizer
that is the identity function; the canonical set itself is an alias table
mapping both PascalCase (identity) and legacy camelCase (`agentStop` → `Stop`,
`promptSubmit` → `UserPromptSubmit`) onto 11 canonical names.

**Verified against:** KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29.

**Command:**

```bash
grep -boF 'buildHookInput' "$bundle"
head -c $((13926615+2320)) "$bundle" | tail -c 2359
```

**Output at capture:**

```
13926615:buildHookInput
13933638:buildHookInput
```

```
// src/hooks/actions/input.ts
function buildHookInput(ctx) {
  const common = {
    session_id: ctx.sessionId,
    hook_event_name: canonicalTriggerName(ctx.trigger),
    cwd: ctx.cwd
  };
  switch (ctx.triggerData.trigger) {
    case "SessionStart" /* SessionStart */:
      return { ...common, hook_event_name: "SessionStart" };
    case "Stop" /* Stop */:
      return {
        ...common,
        hook_event_name: "Stop",
        // `user_decision` is present only when a confirm-gated Stop hook was
        // approved; it carries the selected option id as structured feedback.
        ...ctx.triggerData.userDecision !== void 0 ? { user_decision: ctx.triggerData.userDecision } : {}
      };
    case "Manual" /* Manual */:
      return { ...common, hook_event_name: "Manual" };
    case "UserPromptSubmit" /* UserPromptSubmit */:
      return {
        ...common,
        hook_event_name: "UserPromptSubmit",
        prompt: ctx.triggerData.prompt
      };
    case "PreToolUse" /* PreToolUse */:
      return {
        ...common,
        hook_event_name: "PreToolUse",
        tool_name: ctx.triggerData.toolName,
        tool_input: ctx.triggerData.toolInput
      };
    case "PostToolUse" /* PostToolUse */:
      return {
        ...common,
        hook_event_name: "PostToolUse",
        tool_name: ctx.triggerData.toolName,
        tool_input: ctx.triggerData.toolInput,
        tool_response: ctx.triggerData.toolResponse
      };
    case "PreTaskExec" /* PreTaskExec */:
      return {
        ...common,
        hook_event_name: "PreTaskExec",
        spec_name: ctx.triggerData.specName,
        task_name: ctx.triggerData.taskName
      };
    case "PostTaskExec" /* PostTaskExec */:
      return {
        ...common,
        hook_event_name: "PostTaskExec",
        spec_name: ctx.triggerData.specName,
        task_name: ctx.triggerData.taskName,
        task_success: ctx.triggerData.taskSuccess
      };
    case "PostFileCreate" /* PostFileCreate */:
      return {
        ...common,
        hook_event_name: "PostFileCreate",
        file_path: ctx.triggerData.filePath
      };
    case "PostFileSave" /* PostFileSave */:
      return {
        ...common,
        hook_event_name: "PostFileSave",
        file_path: ctx.triggerData.filePath
      };
    case "PostFileDelete" /* PostFileDelete */:
      return {
        ...common,<<<
```

The truncated final arm is `file_path: ctx.triggerData.filePath`, identical to
its two siblings — confirmed by the arm-count command below, which shows all 11
`hook_event_name` literals.

**Command** (the denominator — how many arms, and are there other payload
builders?):

```bash
grep -boE 'hook_event_name: "[A-Za-z]+"' "$bundle"
```

**Output at capture:**

```
13926872:hook_event_name: "SessionStart"
13926977:hook_event_name: "Stop"
13927332:hook_event_name: "Manual"
13927455:hook_event_name: "UserPromptSubmit"
13927622:hook_event_name: "PreToolUse"
13927837:hook_event_name: "PostToolUse"
13928106:hook_event_name: "PreTaskExec"
13928322:hook_event_name: "PostTaskExec"
13928594:hook_event_name: "PostFileCreate"
13928768:hook_event_name: "PostFileSave"
13928944:hook_event_name: "PostFileDelete"
13966322:hook_event_name: "Stop"
```

**11 of the 12 hits are the switch arms**, covering all 11 canonical triggers
exactly once. The 12th is a **second, separate payload builder** — the one for a
Stop hook's dynamic confirm command, which emits only the three common fields
and no per-trigger extras:

**Command:**

```bash
head -c $((13966240+230)) "$bundle" | tail -c 270
```

**Output at capture:**

```
ult : void 0;
}
function buildConfirmCommandStdin(input) {
  return JSON.stringify({
    session_id: input.sessionId,
    hook_event_name: "Stop",
    cwd: input.cwd
  });
}
async function runConfirmCommand(hook2, input, deps) {
  if (!deps.processRunner || !hook2.confi<<<
```

**Positive controls:** the load-bearing absence here is "no agent, execution,
depth or hook-identity field in the payload". Both halves are read by the same
method — a fixed-string count of the snake_case wire spelling:

```bash
occ() { { grep -boF "$1" "$bundle" || true; } | wc -l; }
for s in session_id hook_event_name tool_name tool_input tool_response \
         spec_name task_name task_success user_decision \
         agent_name execution_id sub_execution_depth workspace_root \
         hook_id hook_name trigger_matched; do
  printf '%-22s %s\n' "$s" "$(occ "$s")"
done
```

```
session_id             15
hook_event_name        13
tool_name              11
tool_input             2
tool_response          1
spec_name              2
task_name              2
task_success           1
user_decision          2
agent_name             0
execution_id           0
sub_execution_depth    0
workspace_root         0
hook_id                0
hook_name              0
trigger_matched        0
```

The first nine rows are the **controls**: every distinctive payload field this
record quotes, found present by the same grep. The last seven are the
**absences** — a hook cannot learn the agent it runs under, the execution it
belongs to, its nesting depth, the workspace root, its own hook id or name, or
which matcher matched. If a re-run reports the absence rows still 0 **and** the
control rows near these values, the negative holds; if the controls collapse
toward 0, the grep has lost the file. `cwd`, `prompt` and `file_path` are
deliberately excluded from the control set: they occur 474, 1666 and 47 times
respectively across unrelated code, so they prove nothing about this payload.

The corresponding **internal** absence — that the engine never asks "am I a
subagent?" in the hook path either — is R-nesting-3 in
`concurrency-and-nesting.md`, which carries its own controls.

**Notes:** the `Stop` arm's `user_decision` is the only **optional** field in
the whole payload; it appears only when a `confirm`-gated Stop hook was approved
and carries the chosen option id. `tool_input` and `tool_response` are
pass-through values with no schema of their own, so their shape follows whatever
the tool used. This record goes stale if an arm gains or loses a field, if the
arm count diverges from the canonical trigger count, or if a third payload
builder appears.

---

## R-hookio-2 — Establish how the hook command is delivered: stdin JSON, an inherited environment with nothing hook-specific added, and exactly one interpolation

**Establishes:** the payload reaches the hook as a **JSON string on stdin**,
written and closed in one call. The spawn passes `env: {}` under a shipped
comment saying so is deliberate, and the runner then merges that empty object
over `process.env` — so the child **inherits the agent's environment** and
receives **no hook-specific variables**. Exactly one interpolation is applied to
the command string on this path: `${WORKSPACE_ROOT}` → the hook's cwd. The
default timeout is **60 seconds** (`DEFAULT_TIMEOUT_SECONDS = 60`, overridable
by the hook document's `timeout` field), and `timeoutSeconds === 0` yields
`timeoutMs = undefined`, i.e. **no timeout at all**.

**Why it matters:** three practical consequences. A hook must parse stdin —
there is no `$KIRO_HOOK_*` to read, and `KIRO_HOME` does not appear anywhere in
the bundle. The inherited environment means a hook sees whatever the agent
process saw, which is a real (if unadvertised) channel and also a real leak
surface — the "env is `{}`" reading of this code is wrong at the OS level. And
`timeout: 0` is not "use the default", it is "run forever", which in a
`Stop`-hook loop is how a turn wedges.

**Semantic anchor:** the command-action class's `execute` does four things in
order before spawning: stringifies the built payload; converts a seconds-valued
timeout to milliseconds, mapping zero to `undefined`; replaces every
`${WORKSPACE_ROOT}` in the author's command string with the cwd; and calls the
injected process runner's `spawn` with
`{command, cwd, env: {}, stdin, signal, timeoutMs}`. The `env: {}` line carries
a three-line comment stating the emptiness is intentional because the runner
layers in `process.env`, and that hook input lives on stdin "per the KAS
contract" to stay structured and avoid env-size limits. The Node runner then
spawns through the platform shell, detached on Unix so the whole process group
can be killed by negative pid, with all three stdio ends piped, and writes the
payload by ending the child's stdin with it. The default timeout constant lives
beside the hook types, not beside the runner.

**Verified against:** KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29.

**Command:**

```bash
head -c $((13938790+700)) "$bundle" | tail -c 730
```

**Output at capture:**

```
();
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
            // env-size limits.
            env: {},
            stdin: stdinJson,
            signal: opts.signal,
            timeoutMs<<<
```

**Command** (the runner side — where `env: {}` actually lands, and how stdin is
written):

```bash
head -c $((13977130+700)) "$bundle" | tail -c 720
head -c $((13979400+90)) "$bundle" | tail -c 130
```

**Output at capture:**

```
ss {
      spawn(opts) {
        return new Promise((resolve24) => {
          const isWin32 = process.platform === "win32";
          const child = spawn(opts.command, {
            cwd: opts.cwd,
            env: { ...process.env, ...opts.env },
            // Run under the platform default shell so `opts.command` is the
            // author-facing free-form string, not an argv array.
            shell: true,
            // Detach on Unix so we can kill the whole process group with a
            // negative pid. Windows doesn't support signals the same way;
            // `child.kill()` is the best we can do there.
            detached: !isWin32,
            stdio: ["pipe", "pipe", "pipe"]
          });
    <<<
```

```
;
          try {
            child.stdin?.end(opts.stdin);
          } catch {
          }
          let resolved = false;
      <<<
```

`env: { ...process.env, ...opts.env }` with `opts.env === {}` is the whole
story: the spread contributes nothing, and the inheritance is unconditional.

**Command** (the timeout default, and its denominator):

```bash
grep -boE 'timeoutSeconds[^,;)]{0,60}' "$bundle"
head -c $((13916590+90)) "$bundle" | tail -c 220
```

**Output at capture:**

```
13934496:timeoutSeconds: hook2.timeoutSeconds
13938844:timeoutSeconds === 0 ? void 0 : opts.timeoutSeconds * 1e3
13946855:timeoutSeconds: doc.timeout ?? DEFAULT_TIMEOUT_SECONDS
13960968:timeoutSeconds: DEFAULT_TIMEOUT_SECONDS
```

```
utedHooks: []
    };
  }
});

// src/hooks/types.ts
var DEFAULT_TIMEOUT_SECONDS;
var init_types21 = __esm({
  "src/hooks/types.ts"() {
    "use strict";
    DEFAULT_TIMEOUT_SECONDS = 60;
  }
});

// src/hooks/executed-ho<<<
```

All four sites are accounted for: the executor handing the hook's own value to
the action, the zero-means-unbounded conversion, the standalone-file loader
defaulting from the document's `timeout`, and the plugin loader which offers no
override at all.

**Command** (the interpolation denominator — is `${WORKSPACE_ROOT}` really the
only one?):

```bash
grep -boE 'replace\(/\\\$(\\\{)?[A-Z_a-z]+(\\\})?(\\b)?/g, [A-Za-z0-9_.]+\)' "$bundle"
```

**Output at capture:**

```
13938948:replace(/\$\{WORKSPACE_ROOT\}/g, opts.cwd)
13954315:replace(/\$\{PLUGIN_ROOT\}/g, pluginRoot)
13954357:replace(/\$\{WORKSPACE_ROOT\}/g, workspaceRoot)
13966676:replace(/\$HOME\b/g, homeDir2)
```

**A correction the denominator forces.** "One path interpolation exists" is true
only of the **spawn** path. There are **four expansion sites in three schemes**,
and two of them are not `${WORKSPACE_ROOT}` at all:

| Offset   | Expansion                      | Where                                       | When              |
| -------- | ------------------------------ | ------------------------------------------- | ----------------- |
| 13938948 | `${WORKSPACE_ROOT}` → `cwd`    | command action, immediately before spawn    | every hook run    |
| 13954315 | `${PLUGIN_ROOT}` → plugin root | open-plugin hooks loader                    | at **load** time  |
| 13954357 | `${WORKSPACE_ROOT}` → ws root  | open-plugin hooks loader                    | at **load** time  |
| 13966676 | `$HOME` → home dir             | Stop hook's dynamic `confirmCommand` runner | confirm gate only |

So `$HOME` is expanded in exactly one place and `${WORKSPACE_ROOT}` is not
expanded there; a plugin-sourced hook has already had its two variables
substituted before the spawn path sees it, and then gets `${WORKSPACE_ROOT}`
substitution again (idempotent, but worth knowing).

**Positive controls:** the absence claim is "no hook-specific environment
variable exists".

```bash
occ() { { grep -boF "$1" "$bundle" || true; } | wc -l; }
for s in KIRO_HOME HOOK_ENV hook_input HOOK_PAYLOAD KIRO_HOOK \
         'env: {}' stdinJson DEFAULT_TIMEOUT_SECONDS WORKSPACE_ROOT; do
  printf '%-24s %s\n' "$s" "$(occ "$s")"
done
```

```
KIRO_HOME                0
HOOK_ENV                 0
hook_input               0
HOOK_PAYLOAD             0
KIRO_HOOK                0
env: {}                  3
stdinJson                2
DEFAULT_TIMEOUT_SECONDS  4
WORKSPACE_ROOT           5
```

The last four rows are the controls: names known present. The first five are the
absences — the environment-variable spellings a hook author would look for, none
of which exists.

**Notes:** `KIRO_HOME` reading zero is a statement about **this bundle only**.
The bundle's home directory comes from a `--home-dir` CLI argument falling back
to `os.homedir()` (`getCliArg("home-dir")`, 1 occurrence; `os10.homedir()`, 1),
so whether an env var reaches that argument is a launcher question this record
does **not** settle. Two runtime details from the runner worth carrying: the
hook runs under the **platform default shell** (`shell: true`), so shell
metacharacters in the command string are live; and on timeout or cancellation
the runner sends `SIGTERM` to the whole process group and escalates to `SIGKILL`
after a 2 s grace period. `child.stdin.end(payload)` writes with **no trailing
newline** and closes immediately, so a script must read to EOF rather than read
a line. This record goes stale if `env` stops being `{}`, if the runner stops
merging `process.env`, if the default changes from 60, or if the
zero-means-unbounded mapping changes.

---

## R-hookio-3 — Establish the empty-prompt defect and its cause: the prompt-hook path drops the real prompt text and fabricates an empty one

**Establishes:** a `UserPromptSubmit` command hook receives `prompt: ""` — never
the user's text. The cause is a **dropped parameter**. The provider interface is
`executeHookAction(hook, state, userPrompt)`, the graph calls it with the real
prompt text as the third argument, and the in-process provider's implementation
declares only **two** parameters. Having no prompt to pass, it fills trigger
data from `buildMinimalTriggerData(loaded.trigger)`, whose `UserPromptSubmit`
arm returns `{ trigger, prompt: "" }`. `buildHookInput` (R-hookio-1) then
faithfully emits that empty string.

**Why it matters:** this is a genuine defect, not a design choice, and it is
invisible from the outside — a hook that reads `.prompt` gets a well-formed
payload with an empty field, indistinguishable from a user submitting nothing.
It kills every design that wanted to inspect, classify, validate or route on the
task text at prompt-submit time. Designs that read shared state instead of the
prompt (a queue, a ledger, a file) are unaffected, which is why the defect can
survive a working end-to-end test.

**That the same provider gets it right one function away is what makes it a
defect.** Its `SessionStart` sibling hand-builds its trigger data and carries a
comment explaining that it threads the session id through _specifically so
command hooks see a non-empty `session_id` in their JSON stdin_. The care is
present; it just was not applied to the prompt.

**Semantic anchor:** three sites, in the order the value is lost.

1. In the user-hook graph node's per-trigger executor loop, each non-agent hook
   is dispatched through the session services' hook provider with **three**
   arguments: the hook, the current state, and a cleaned prompt string
   (`cleanUserPrompt`) that the enclosing function computes by taking the last
   non-empty human message's text and truncating it at the first
   `<HOOK_INSTRUCTION>` marker. So the real text is not merely available — it
   has been deliberately prepared.
2. The in-process hooks provider's `executeHookAction` **omits the third
   parameter from its signature**, looks the hook up in the live registry, and
   passes the executor a trigger-data object built by a "minimal satisfying
   fields" helper, under a comment framing this as the _manual single-hook path_
   — which is the tell that this path was written for the manual trigger and
   then reused for the prompt triggers.
3. That helper is a switch mirroring R-hookio-1's arms, returning **empty-string
   and `undefined` placeholders** for every field: `toolName: ""`,
   `toolInput: void 0`, `specName: ""`, `taskSuccess: false`, `filePath: ""`,
   and `prompt: ""`.

The reason this path is reached at all is the second engine-shape fact in the
header: the properly-populating per-trigger entry point for `UserPromptSubmit`
exists but is never called.

**Verified against:** KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29.

**Command** (the one-line proof — two implementations of one interface, side by
side):

```bash
grep -boE 'async executeHookAction\(hook2, state2[^)]*\)' "$bundle"
```

**Output at capture:**

```
19810946:async executeHookAction(hook2, state2, userPrompt)
19823407:async executeHookAction(hook2, state2)
```

The first is the ACP-delegating provider, which forwards `userPrompt` to the
client. The second is the in-process provider — the one a v3 CLI session uses —
which does not.

**Command** (the call site that passes the real text):

```bash
head -c $((14068936+250)) "$bundle" | tail -c 470
```

**Output at capture:**

```
HookPrompt(currentState, hook2, userPromptText);
      } else {
        emitHookInvoked(currentState.execution, toContextualExecutedHook(hook2));
        currentState = await currentState.execution.sessionServices.hooks.executeHookAction(
          hook2,
          currentState,
          context3.cleanUserPrompt
        );
      }
    } catch {
      if (hook2.action.type === "askAgent") {
        Metrics13.reportCountMetrics({ askAgentActionFailed: 1 });
      } e<<<
```

**Command** (the fabrication site, with its shipped comment):

```bash
head -c $((19824504+40)) "$bundle" | tail -c 620
```

**Output at capture:**

```
eturn state2;
      }
      const controller = new AbortController();
      const rs2 = await v2.executor.execute([loaded], {
        trigger: loaded.trigger,
        sessionId: state2.chatSessionId,
        cwd: workspaceRoot,
        signal: controller.signal,
        matchContext: { trigger: loaded.trigger },
        // The triggerData shape is constrained by HookTriggerData's
        // discriminated union. For the manual single-hook path we use the
        // hook's own trigger as the discriminator and provide minimal
        // satisfying fields.
        triggerData: buildMinimalTriggerData(loaded.trigger)<<<
```

**Command** (the fabricator itself — every arm, so the blast radius is on
record):

```bash
head -c $((19828740+520)) "$bundle" | tail -c 950
```

**Output at capture:**

```
esult
      });
      emitExecutedHooks(state2, out.executedHooks);
      return { state: state2, hookMessage: out.hookMessage };
    }
  };
}
function buildMinimalTriggerData(trigger) {
  switch (trigger) {
    case "SessionStart" /* SessionStart */:
    case "Stop" /* Stop */:
    case "Manual" /* Manual */:
      return { trigger };
    case "PreToolUse" /* PreToolUse */:
      return { trigger, toolName: "", toolInput: void 0 };
    case "PostToolUse" /* PostToolUse */:
      return { trigger, toolName: "", toolInput: void 0, toolResponse: void 0 };
    case "PreTaskExec" /* PreTaskExec */:
      return { trigger, specName: "", taskName: "" };
    case "PostTaskExec" /* PostTaskExec */:
      return { trigger, specName: "", taskName: "", taskSuccess: false };
    case "UserPromptSubmit" /* UserPromptSubmit */:
      return { trigger, prompt: "" };
    case "PostFileCreate" /* PostFileCreate */:
    case "PostFileSave" /* PostFileSav<<<
```

**Command** (the contrast — the same provider's `SessionStart` path, which does
hand-build correct trigger data and says why):

```bash
head -c $((19821844+660)) "$bundle" | tail -c 700
```

**Output at capture:**

```
uppressedUntrusted", {
          site: "extractPrecomputedResults",
          trigger: "SessionStart" /* SessionStart */,
          count: matched.length
        });
        return [];
      }
      const controller = new AbortController();
      const rs2 = await v2.executor.execute(matched, {
        trigger: "SessionStart" /* SessionStart */,
        // The session id is threaded from GraphState so SessionStart command
        // hooks see a non-empty `session_id` in their JSON stdin, matching the
        // other triggers (and v2/agentSpawn parity).
        sessionId: state2.chatSessionId,
        cwd: workspaceRoot,
        signal: controller.signal,
        matchContext: { trigger: "Se<<<
```

**Positive controls:** this record asserts that the correctly-populating
per-trigger paths are **never called**, so it needs controls proving the same
grep form finds the paths that _are_ called.

```bash
occ() { { grep -boF "$1" "$bundle" || true; } | wc -l; }
for s in 'runUserPromptSubmitHooks' '.userPromptSubmit(' 'runSessionStartHooks' \
         '.sessionStart(' 'runManualHooks' '.manual(' 'triggers.preToolUse' \
         'triggers.postToolUse' 'triggers.stop' 'buildMinimalTriggerData' \
         'executeHookAction' 'extractPrecomputedResults'; do
  printf '%-26s %s\n' "$s" "$(occ "$s")"
done
```

```
runUserPromptSubmitHooks   2
.userPromptSubmit(         0
runSessionStartHooks       2
.sessionStart(             0
runManualHooks             2
.manual(                   0
triggers.preToolUse        1
triggers.postToolUse       1
triggers.stop              1
buildMinimalTriggerData    2
executeHookAction          7
extractPrecomputedResults  7
```

Read as pairs. `runUserPromptSubmitHooks` = 2 is definition + registration, and
`.userPromptSubmit(` = 0 proves nothing invokes it — while `triggers.preToolUse`
/ `.postToolUse` / `.stop` each = 1 prove the same grep form **does** find live
trigger invocations. So the zeros are real absences, not a lost grip on the
file.

**Notes:** the blast radius of `buildMinimalTriggerData` is narrower than its
switch suggests. It is reached only from the single-hook `executeHookAction`
path, and only `promptSubmit`, `agentStop` and `sessionStart` are routed there
(a separate narrowing function returns `undefined` for the four tool/task
triggers, which is why tool hooks get real payloads — see R-hookio-4).
`SessionStart` and `Stop` arms carry no extra fields, so they are harmless;
`UserPromptSubmit`'s `prompt` is **the only field this path can lie about**.
This record goes stale in the good way if the in-process implementation grows
the third parameter — check that grep first, before anything else, since a fix
would show there and nowhere else.

---

## R-hookio-4 — Establish the stdout/blocking decision function, the three consequences that read backwards, and the two triggers that bypass it

**Establishes:** one pure function of (trigger, exit code) is the declared
contract for whether a command hook's stdout is injected, its stderr is
injected, and the action is blocked — and **two triggers bypass it**. It returns
one of three frozen constants. Blocking is available to exactly three triggers —
`UserPromptSubmit`, `PreToolUse`, `PreTaskExec` — and only on exit code **2**.
Stdout injection is available to exactly two — `SessionStart`,
`UserPromptSubmit` — and only on exit code **0**. Every other combination is
`DECISION_NONE`: nothing injected, nothing blocked.

**Why it matters:** the three consequences all cut against intuition, and the
last two silently discard work a hook author believes is being used.

1. **`PreToolUse` blocks but cannot speak on success.** Its exit-2 path injects
   stderr and halts the call; its exit-0 stdout falls through to `DECISION_NONE`
   and is **discarded**. A pre-tool hook that prints advice and exits 0 has
   printed into a void. Its only exit-0 channel is the structured decision of
   R-hookio-5, which is parsed from the same stdout the decision function throws
   away.
2. **`PostToolUse` and the three `PostFile*` triggers never inject and never
   block** — they are absent from both lists, so a command hook there is
   fire-and-forget by construction. That makes them the safest observers in the
   system (they cannot perturb a turn) and useless as gates.
3. **`Stop` is not a blocking trigger, so its exit 2 does nothing.** Its
   productive exit code is **1**, via a different function entirely
   (R-hookio-6).
4. **For `SessionStart` and `UserPromptSubmit` the function is BYPASSED
   entirely.** Those two triggers travel the single-hook provider path of
   R-hookio-3, which reads `commandResult.stdout || commandResult.stderr`
   **directly** rather than the decision-gated appendix. So their stdout is
   injected **regardless of exit code**, their stderr is injected whenever
   stdout is empty, and `UserPromptSubmit` — nominally a blocking trigger —
   **does not block**: its exit code is appended to the conversation as the
   literal text `Exit Code: N` instead of being acted on.

**And the shipped documentation contradicts consequence 1.** The bundle's own
hook-authoring guidance states
`exit 0 — success; stdout forwarded for SessionStart/UserPromptSubmit/PreToolUse`.
The code forwards it for the first two only. Trust the function.

**Semantic anchor:** in the hooks output module, a small function derives a
local boolean naming the three triggers for which exit 2 means "block", then
applies four rules in order: exit 2 on a blocking trigger → the
block-with-stderr constant; exit 0 on session start → the stdout constant; exit
0 on prompt submit → the stdout constant; otherwise the do-nothing constant. The
three constants are `Object.freeze`d records of three booleans (`sendStdout`,
`sendStderr`, `block`), declared in the module's initializer rather than inline.
A companion in the executor turns a decision plus the captured streams into the
text actually appended, concatenating only the enabled streams and inserting a
newline between them if needed; the result is then wrapped in
`<HOOK_INSTRUCTION>` tags and accumulated across the batch.

**Verified against:** KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29.

**Command:**

```bash
head -c $((13929253+1000)) "$bundle" | tail -c 1010
```

**Output at capture:**

```
ode) {
  const isBlockingTrigger = trigger === "UserPromptSubmit" /* UserPromptSubmit */ || trigger === "PreToolUse" /* PreToolUse */ || trigger === "PreTaskExec" /* PreTaskExec */;
  if (exitCode === 2 && isBlockingTrigger) {
    return DECISION_BLOCK_STDERR;
  }
  if (exitCode === 0 && trigger === "SessionStart" /* SessionStart */) {
    return DECISION_STDOUT;
  }
  if (exitCode === 0 && trigger === "UserPromptSubmit" /* UserPromptSubmit */) {
    return DECISION_STDOUT;
  }
  return DECISION_NONE;
}
var DECISION_NONE, DECISION_STDOUT, DECISION_BLOCK_STDERR;
var init_output = __esm({
  "src/hooks/actions/output.ts"() {
    "use strict";
    init_types21();
    DECISION_NONE = Object.freeze({
      sendStdout: false,
      sendStderr: false,
      block: false
    });
    DECISION_STDOUT = Object.freeze({
      sendStdout: true,
      sendStderr: false,
      block: false
    });
    DECISION_BLOCK_STDERR = Object.freeze({
      sendStdout: false,
      sendStderr: true,
      block: true
    <<<
```

The truncated tail is `});` closing `DECISION_BLOCK_STDERR`.

**Command** (the shipped documentation that disagrees — quoted so the drift is
on record, not paraphrased):

```bash
head -c $((5069050+960)) "$bundle" | tail -c 970
```

**Output at capture:**

```
 Alternately, direct them to use the command palette to 'Open Kiro Hook UI' to start building a new hook
- Hook files follow this schema:

\`\`\`json
{
  "version": "v1",
  "hooks": [{
    "name": "<name>",
    "trigger": "<Trigger>",
    "matcher": "<optional regex>",
    "action": { "type": "command", "command": "<shell command>" }
  }]
}
\`\`\`

Action types:
  command \u2014 runs a shell command; receives JSON on stdin with session context
  agent   \u2014 appends a static prompt to the model context

Exit-code semantics for command actions:
  exit 0  \u2014 success; stdout forwarded for SessionStart/UserPromptSubmit/PreToolUse
  exit 2  \u2014 block the action (PreToolUse, UserPromptSubmit, PreTaskExec); stderr forwarded
  other   \u2014 silent failure, no block

For PreToolUse hooks, exit 0 stdout may contain a JSON decision:
  {"hookSpecificOutput":{"permissionDecision":"ask","permissionDecisionReason":"reason"}}
  When permissionDecision is "ask", <<<
```

The `\u2014` sequences are literal bytes in the bundle (esbuild-escaped em
dashes), not an artifact of the window — expect them verbatim on replay. Note
the exit-2 line matches the code exactly, and the exit-0 line does not.

**Resulting table, derived from the function rather than from prose:**

What the function itself says, before the bypass is applied:

| Trigger                                       | exit 0 stdout                  | exit 2                   | Blocking? |
| --------------------------------------------- | ------------------------------ | ------------------------ | --------- |
| `SessionStart`                                | injected                       | nothing                  | no        |
| `UserPromptSubmit`                            | injected                       | blocks, stderr shown     | yes       |
| `PreToolUse`                                  | **discarded** (see R-hookio-5) | **blocks**, stderr shown | yes       |
| `PreTaskExec`                                 | discarded                      | **blocks**, stderr shown | yes       |
| `PostToolUse`, `PostFile{Create,Save,Delete}` | discarded                      | nothing                  | no        |
| `Stop`                                        | see R-hookio-6                 | nothing                  | no        |
| `Manual`, `PostTaskExec`                      | discarded                      | nothing                  | no        |

**And what actually reaches the model on the in-process binding**, once
consequence 4 is applied to the first two rows:

| Trigger            | Injected                                                                    | Blocks? |
| ------------------ | --------------------------------------------------------------------------- | ------- |
| `SessionStart`     | stdout, else stderr — **any** exit code                                     | no      |
| `UserPromptSubmit` | stdout, else stderr, **plus** a literal `Exit Code: N` line — any exit code | **no**  |

The rows below those two are unaffected: they travel the per-trigger modules,
which consume the decision-gated appendix.

**Command** (the bypass — both sites read the raw streams, and the split between
raw readers and appendix consumers is exact):

```bash
grep -boE 'commandResult\.stdout \|\| r5\.commandResult\.stderr' "$bundle"
head -c $((19822980+330)) "$bundle" | tail -c 350
head -c $((19824700+400)) "$bundle" | tail -c 420
```

**Output at capture:**

```
19823061:commandResult.stdout || r5.commandResult.stderr
19824682:commandResult.stdout || r5.commandResult.stderr
```

```
       });
          }
        } else if (r5.commandResult !== void 0) {
          const output = r5.commandResult.stdout || r5.commandResult.stderr;
          if (output) {
            results.push({
              id: r5.hookId,
              name: r5.hookName,
              hookId: r5.hookId,
              originalType: "runCommand",<<<
```

```
5.commandResult.stdout || r5.commandResult.stderr;
      const outputText = `Output:
${output}

Exit Code: ${String(r5.commandResult.exitCode)}`;
      return {
        ...state2,
        context: state2.context.withNewMessage(
          ContextChatMessage.fromHuman().withEntry({ text: outputText, type: "text" })
        )
      };
    },
    runStopHooks: runStopHooks2
  };
  async function runStopHooks2(state2) {<<<
```

**Exactly two** raw readers, and they are precisely the `SessionStart`
precomputed path and the `UserPromptSubmit` single-hook path — the same two the
header notes have no per-trigger call site. Neither consults
`resolveHookOutput`, neither reads `blocked`, and the second one turns the exit
code into prose. Note also that `stdout || stderr` means an empty stdout
promotes **stderr** into the conversation, on any exit code — so a hook that
logs progress to stderr and succeeds silently will have its log injected as if
it were output.

**Positive controls:** the load-bearing claims are absences — no
`DECISION_STDOUT` branch for post-tool-use or post-file, and no allow/deny
decision constants.

```bash
occ() { { grep -boF "$1" "$bundle" || true; } | wc -l; }
for s in DECISION_NONE DECISION_STDOUT DECISION_BLOCK_STDERR resolveHookOutput \
         isBlockingTrigger decisionPayload sendStdout sendStderr \
         'DECISION_STDOUT_POSTTOOLUSE' 'PostToolUseStdout' 'DECISION_ALLOW' 'DECISION_DENY'; do
  printf '%-28s %s\n' "$s" "$(occ "$s")"
done
```

```
DECISION_NONE                3
DECISION_STDOUT              4
DECISION_BLOCK_STDERR        3
resolveHookOutput            2
isBlockingTrigger            2
decisionPayload              2
sendStdout                   4
sendStderr                   4
DECISION_STDOUT_POSTTOOLUSE  0
PostToolUseStdout            0
DECISION_ALLOW               0
DECISION_DENY                0
```

The first eight rows are controls: the decision machinery is present and
parseable. The last four are absences — the constants a post-hook injection path
or an allow/deny vocabulary would have needed. `DECISION_STDOUT` = 4 is exactly
its declaration plus the three references (two in the function, one in the
declaration list), so there is no fourth injection branch hiding elsewhere.

**Notes:** one carve-out keeps the "never injects" claim honest. The accumulated
appendix is built from `result.appendix`, and for an **agent**-kind hook that
appendix is a static prompt fragment produced by a different action class which
`resolveHookOutput` never sees. So a **command** hook on `PostToolUse` can never
inject, while an **agent** hook on `PostToolUse` can — the trigger modules do
return `hookMessage: rs2?.combinedAppendix || void 0` on the post paths, and the
executors do propagate it. Two smaller details: a batch does not short-circuit
on a block (the executor runs every matched hook and reports `anyBlocked`
afterwards, with a shipped comment explaining that cancelling peers would hide
telemetry), and a file **creation** fires `PostFileCreate` _and_ `PostFileSave`
in that order. This record goes stale if a trigger joins or leaves either list,
if a fourth decision constant appears, if either raw reader starts consulting
the decision function (which would make consequence 4 obsolete — check the
two-hit grep first), or if the shipped guidance is corrected, in which case the
drift note should be retired rather than kept.

---

## R-hookio-5 — Establish the pre-tool-use escape hatch: structured stdout that requests user confirmation

**Establishes:** a `PreToolUse` hook exiting **0** may print a JSON object whose
`hookSpecificOutput.permissionDecision` is the exact string `"ask"`; the runtime
then prompts the user to confirm before the tool proceeds, showing
`hookSpecificOutput.permissionDecisionReason` if it is a string. This is parsed
from the same stdout that R-hookio-4 discards, so it is the **only** exit-0
channel `PreToolUse` has. `"allow"`, `"deny"`, a non-object, a missing
`hookSpecificOutput`, or unparseable JSON all yield no decision — silently.

**Why it matters:** it converts an all-or-nothing block into a human-in-the-loop
gate, which is the difference between a policy hook that halts work and one that
escalates. It is also the one place where a hook's stdout has structure the
runtime interprets, and the shape is exact and undocumented beyond a single line
of shipped guidance — a typo in the nesting produces no decision and no
diagnostic.

**Semantic anchor:** the executor computes the decision-payload text for every
command hook, then **conditionally** parses the raw stdout a second time: only
when the trigger is pre-tool-use _and_ the exit code is 0. The parser trims,
`JSON.parse`es inside a `try`, rejects non-objects and null, reads the
`hookSpecificOutput` property, rejects it if it is not an object, reads
`permissionDecision`, and returns an ask-flag plus an optional reason **only if
that value is the literal `"ask"`**; every other path returns undefined. Its
sibling parser for stop decisions sits directly below and differs in one
important way — it accepts the decision fields either nested under
`hookSpecificOutput` _or_ at the top level. Downstream, the pre-tool-use trigger
module surfaces the first asking hook's reason, and the session's pre-tool-use
executor calls an injected permission handler with it; when no handler is wired
the call is **denied** with an explanatory message rather than allowed.

**Verified against:** KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29.

**Command:**

```bash
head -c $((13930956+560)) "$bundle" | tail -c 600
```

**Output at capture:**

```
obj["hookSpecificOutput"];
    if (typeof hookOutput !== "object" || hookOutput === null) return void 0;
    const decision = hookOutput["permissionDecision"];
    if (decision === "ask") {
      const reason = hookOutput["permissionDecisionReason"];
      return { ask: true, reason: typeof reason === "string" ? reason : void 0 };
    }
    return void 0;
  } catch {
    return void 0;
  }
}
function parseStopDecision(stdout) {
  if (!stdout.trim()) return void 0;
  try {
    const parsed2 = JSON.parse(stdout);
    if (typeof parsed2 !== "object" || parsed2 === null) return void 0;
    const o<<<
```

**Command** (the guard that makes it pre-tool-use-and-exit-0 only):

```bash
head -c $((13934670+330)) "$bundle" | tail -c 360
```

**Output at capture:**

```
        const piece = decisionPayload(cmdResult.stdout, cmdResult.stderr, decision);
              const parsed2 = ctx.trigger === "PreToolUse" /* PreToolUse */ && cmdResult.exitCode === 0 ? parseHookDecision(cmdResult.stdout) : void 0;
              const stopDecision = ctx.trigger === "Stop" /* Stop */ ? resolveStopContinueDecision(cmdResult.exitCode, cmdR<<<
```

Note `piece` (the discarded payload) and `parsed2` (the honored decision) are
computed from the **same** `cmdResult.stdout` on adjacent lines. That is the
whole asymmetry in two statements.

**Command** (what happens to the ask, including the no-handler default):

```bash
head -c $((19827756+60)) "$bundle" | tail -c 790
```

**Output at capture:**

```
te2,
          hookMessage: result.blockedReason ?? result.hookMessage ?? ""
        };
      }
      if (result.ask && askUser) {
        const reason = result.askReason ?? `Hook requires confirmation for tool "${toolId}".`;
        const approved = await askUser(reason, toolId);
        if (!approved) {
          return {
            state: state2,
            hookMessage: `User denied tool "${toolId}". Reason shown: ${reason}`
          };
        }
      } else if (result.ask) {
        return {
          state: state2,
          hookMessage: `Hook requested confirmation for tool "${toolId}" but no permission handler is available. Denying.`
        };
      }
      const nextState = result.hookMessage ? { ...state2, skipHooksForNextToolCall: [...skipList, toolId] } : state2;<<<
```

**The exact shape, quoted from the shipped guidance** (the same string captured
in full in R-hookio-4):

```
  {"hookSpecificOutput":{"permissionDecision":"ask","permissionDecisionReason":"reason"}}
```

**Positive controls:** this record asserts that no allow/deny vocabulary exists.

```bash
occ() { { grep -boF "$1" "$bundle" || true; } | wc -l; }
for s in parseHookDecision permissionDecision permissionDecisionReason \
         hookSpecificOutput askReason anyAsked \
         permissionDecisionAllow permissionDecisionDeny suppressOutput; do
  printf '%-26s %s\n' "$s" "$(occ "$s")"
done
```

```
parseHookDecision          2
permissionDecision         8
permissionDecisionReason   3
hookSpecificOutput         4
askReason                  4
anyAsked                   6
permissionDecisionAllow    0
permissionDecisionDeny     0
suppressOutput             0
```

First six rows are controls; last three are absences. Do **not** control on the
bare strings `"allow"` / `"deny"` — they occur 141 and 54 times across unrelated
permission machinery, so they prove nothing about this parser. The
`permissionDecision` = 8 breaks down as 3 occurrences (decision + reason +
mention) inside each of **two identical copies of the shipped guidance string**,
plus 2 in the parser: a useful reminder that this bundle ships some prompt text
twice.

**Notes:** the reason is optional and non-strings are dropped rather than
stringified, so `"permissionDecisionReason": 42` produces an ask with the
generic fallback message. There is **no** allow-and-suppress or deny-outright
decision: the only stdout-driven outcomes are "ask" and "nothing", and outright
blocking remains exit 2. This record goes stale if the parser accepts a second
decision value, if it starts accepting top-level fields the way the stop parser
does, or if the no-handler default flips from deny to allow — that last one
being a security change worth checking on every upgrade.

---

## R-hookio-6 — Establish that a Stop hook exiting 1 is a loop primitive: it injects script-authored text as a new message and restarts the graph

**Establishes:** a `Stop` command hook exiting **1** produces a continuation.
Its `stderr` (falling back to `stdout`) becomes a _reason_; the reason is capped
at **4000 characters** and suffixed `… [truncated]` beyond that; an empty reason
is replaced by a fixed default; the reason is wrapped in
`<HOOK_INSTRUCTION>`/`</HOOK_INSTRUCTION>`, appended as a **new human message**,
and the state is returned with `shouldRestartGraph: true` — so the turn
continues instead of ending. Exit **0** offers a JSON alternative
(`{"decision":"block","reason":…}`, accepted nested or top-level). Every other
exit code, **including 2**, produces no continuation at all.

**Why it matters:** this is not a completion signal, it is a **deterministic
in-session loop driver**. The content that re-enters the conversation is
authored by a script, not by the model, and the restart is unconditional — so a
script can hand a worker its next instruction and the turn keeps going. That
makes "keep working until my condition holds" implementable without model
discipline. Two constraints ride with it: the injected text has a hard
4000-character budget, and because the restart is state-driven there is nothing
stopping a hook that always exits 1 from looping forever. The cap is a
truncation, not a rejection — an over-long reason is silently shortened, which
is the failure mode to design against.

**Semantic anchor:** three layers, each in a different module.

1. **Resolution.** A function of (exit code, stdout, stderr) returns a
   continue-decision. Exit 1 takes `stderr.trim() || stdout.trim()` as the
   reason and returns continue-true with the reason (or undefined if both were
   empty). Exit 0 delegates to the stop-decision JSON parser. Anything else
   returns undefined. Note the **stderr-first** precedence — the opposite of
   what a "print your reason" instinct suggests.
2. **Normalization.** The provider adapter maps the trigger result onto a
   `{kind: "stop"}` / `{kind: "continue", reason}` union, running the reason
   through a length-capping helper and substituting a default reminder string
   when the reason is empty. The cap constant and the default reminder are
   declared together in a stop-decision module.
3. **Application.** The agent-stop graph handler applies the decision to the
   restart prompt text — wrapping a continue reason in hook-instruction tags,
   appending to any existing text — and, if the result is non-blank, builds a
   new human message from it, appends it to the context, and returns state with
   the restart flag set. There is exactly **one** assignment of that flag in the
   whole bundle. The router downstream reads it and re-enters the graph rather
   than ending the turn.

**Verified against:** KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29.

**Command:**

```bash
head -c $((13931896+320)) "$bundle" | tail -c 350
```

**Output at capture:**

```
return void 0;
  }
}
function resolveStopContinueDecision(exitCode, stdout, stderr) {
  if (exitCode === 1) {
    const reason = stderr.trim() || stdout.trim();
    return { continue: true, reason: reason.length > 0 ? reason : void 0 };
  }
  if (exitCode === 0) {
    return parseStopDecision(stdout);
  }
  return void 0;
}
var HOOK_INSTRUCTION_OPE<<<
```

**Command** (the cap, the truncation marker, and the default reminder):

```bash
head -c $((13915900+560)) "$bundle" | tail -c 580
```

**Output at capture:**

```
ENGTH) {
    return trimmed;
  }
  return `${trimmed.slice(0, MAX_STOP_REASON_LENGTH)}\u2026 [truncated]`;
}
var MAX_STOP_REASON_LENGTH, DEFAULT_REMINDER, defaultReminderReasonText, emptyStopHooksOutcome;
var init_stop_decision = __esm({
  "src/hooks/stop-decision.ts"() {
    "use strict";
    MAX_STOP_REASON_LENGTH = 4e3;
    DEFAULT_REMINDER = "A Stop hook requested that you keep working before ending the turn.";
    defaultReminderReasonText = parseReasonText(DEFAULT_REMINDER) ?? DEFAULT_REMINDER;
    emptyStopHooksOutcome = {
      decision: { kind: "stop" },
      exec<<<
```

**Command** (the normalization, and the injection plus restart):

```bash
head -c $((19825582+120)) "$bundle" | tail -c 330
head -c $((14065850+600)) "$bundle" | tail -c 640
grep -boE 'shouldRestartGraph: true' "$bundle"
```

**Output at capture:**

```
 toExecutedHook({ hookId: h5.id, hookName: h5.name, action: "command" /* Command */ })
    ) ?? [];
    if (!res.continue) {
      return { decision: { kind: "stop" }, executedHooks };
    }
    const reason = parseReasonText(res.reason ?? "") ?? defaultReminderReasonText;
    return { decision: { kind: "continue", reason }, exe<<<
```

```
erMessage = ContextChatMessage.fromHuman().withText(restartPromptText);
  return {
    ...updatedState,
    context: updatedState.context.withNewMessage(newUserMessage),
    shouldRestartGraph: true
  };
}
function applyStopDecision(text, decision) {
  switch (decision.kind) {
    case "stop":
      return text;
    case "continue": {
      const wrapped = `<HOOK_INSTRUCTION>
${decision.reason}
</HOOK_INSTRUCTION>`;
      return text.trim() === "" ? wrapped : `${text}

${wrapped}`;
    }
    default:
      return assertNever4(decision);
  }
}
async function handlePrecomputedTrigger(state2, triggerType) {
  const results = await stat<<<
```

```
14065984:shouldRestartGraph: true
```

**Positive controls:** the absence asserted here is that **no other exit code
continues** and that the restart flag is set in exactly one place.

```bash
occ() { { grep -boF "$1" "$bundle" || true; } | wc -l; }
for s in resolveStopContinueDecision parseStopDecision MAX_STOP_REASON_LENGTH \
         HOOK_INSTRUCTION shouldRestartGraph applyStopDecision \
         DEFAULT_REMINDER; do
  printf '%-30s %s\n' "$s" "$(occ "$s")"
done
```

```
resolveStopContinueDecision    2
parseStopDecision              2
MAX_STOP_REASON_LENGTH         4
HOOK_INSTRUCTION               31
shouldRestartGraph             10
applyStopDecision              2
DEFAULT_REMINDER               4
```

All rows are controls (present); the absence is structural rather than
string-shaped — the function's only branches are `=== 1` and `=== 0`, both
quoted verbatim above, with a bare `return void 0` fallthrough.
`shouldRestartGraph` = 10 against exactly **1** occurrence of
`shouldRestartGraph: true` is the denominator that matters: the other 9 are the
state annotation, reads and router conditions, not additional setters.
`DEFAULT_REMINDER` = 4 is the `var` declaration, the assignment, and the two
uses on the `defaultReminderReasonText` line.

**Notes:** only **command**-kind Stop hooks reach this path — the trigger module
filters candidates to `action.kind === "command"`, while the graph's separate
extraction path filters Stop candidates to **agent**-kind only, so the two kinds
travel entirely different routes for the same trigger. A `Stop` hook may also
carry a `confirm` block with a static question or a dynamic `confirmCommand`;
the confirm command gets its own three-field payload (R-hookio-1) and its own
`$HOME` expansion (R-hookio-2), and its approval is what populates the payload's
`user_decision`. If multiple Stop hooks continue, their reasons are joined with
a blank line **before** capping, so the 4000 characters are shared across the
batch. This record goes stale if exit 1 stops continuing, if the cap changes, if
stderr-first precedence flips, or if a second `shouldRestartGraph: true`
appears.

---

## R-hookio-7 — Establish that hooks load from the home directory alongside every workspace root

**Establishes:** the standalone hook loader scans `.kiro/hooks/*.json` under
**two** classes of root: the session's workspace roots, and a set of _global_
roots that always contains the **home directory** (plus a cloud-replica root
when one is wired). Workspace roots are scanned first, then globals; a workspace
root whose hooks directory is the same as a global one is skipped with a debug
log so it is not scanned twice.

**Why it matters:** it refutes the natural reading that v3 hooks are
workspace-local. A hook placed at `~/.kiro/hooks/<name>.json` loads in **every**
session, which is what makes hooks shippable by a user-level configuration
manager rather than per-repo. It also means a global hook fires in workspaces
you did not think about, so a global hook must be written to be harmless where
it does not apply.

**Semantic anchor:** the module factory that assembles the hooks subsystem takes
a `globalHookRoots` array and hands it to the standalone loader as its
`globalRoots` while workspace roots go in separately. The cache that creates one
hooks module per workspace-root set computes that array inline, under a
three-line comment stating that global hooks are user-level, independent of
workspace roots, scanned once from the home directory and applied across every
workspace, and that a cloud replica root joins them additively and can never
shadow a local hook. The loader's `loadAll` iterates workspace roots (skipping
any whose hooks directory key matches a global one), then iterates globals,
concatenating. Its per-root loader joins the root with a module constant that is
`path.join(".kiro", "hooks")` and filters for a `.json` extension constant.

**Verified against:** KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29.

**Command:**

```bash
grep -boF 'globalHookRoots' "$bundle"
head -c $((14051812+240)) "$bundle" | tail -c 700
```

**Output at capture:**

```
13983416:globalHookRoots
14051812:globalHookRoots
```

```
        if (existing) {
          return existing;
        }
        const module = createHooksModule({
          workspaceRoots,
          // Global hooks are user-level and independent of workspace roots: scanned
          // once from the home directory, applied across every workspace. The cloud
          // replica root, when a source is wired, joins them as an additive global
          // root (path-id, so it can never shadow a local hook).
          globalHookRoots: this.sharedDeps.cloudHookRoot !== void 0 ? [this.sharedDeps.cloudHookRoot, this.sharedDeps.homeDir] : [this.sharedDeps.homeDir],
          homeDir: this.sharedDeps.homeDir,
          fs: this.sharedDeps.fs,
          proces<<<
```

Two occurrences, both accounted for: the parameter the factory consumes, and
this single construction site — so there is no second, differently-populated set
of global roots.

**Command** (the scan order, and the overlap skip):

```bash
head -c $((13948700+780)) "$bundle" | tail -c 800
grep -boE 'HOOKS_SUBDIR = [^;]*|JSON_EXTENSION = [^;]*' "$bundle"
```

**Output at capture:**

```
et(this.globalRoots.map(hooksDirKey));
        const loaded = [];
        for (const root5 of wsRoots) {
          if (globalHookDirs.has(hooksDirKey(root5))) {
            this.deps.logger.debug("hooks.load.workspaceRootOverlapsGlobal", { root: root5 });
            continue;
          }
          const rootHooks = await this.loadRoot(root5);
          loaded.push(...rootHooks);
        }
        for (const root5 of this.globalRoots) {
          const rootHooks = await this.loadRoot(root5);
          loaded.push(...rootHooks);
        }
        if (loaded.length > 0) {
          this.deps.telemetry?.reportCount("hooks.loaded", {
            source: "standalone-file" /* StandaloneFile */,
            count: String(loaded.length)
          });
        }
        return loaded;
      }<<<
```

```
13947695:HOOKS_SUBDIR = path8.join(".kiro", "hooks")
13947744:JSON_EXTENSION = ".json"
```

**Positive controls:** not required — this record asserts a presence. The
related absence (that a home-relocation environment variable is not visible in
this bundle) is carried by R-hookio-2's controls.

**Notes:** what "the home directory" resolves to is set outside the hooks
subsystem: it is a `--home-dir` CLI argument falling back to `os.homedir()`
(`getCliArg("home-dir")` and `os10.homedir()`, one occurrence each), and
`KIRO_HOME` appears **zero** times in this bundle. So whether an environment
variable can relocate the global hook root is a **launcher** question that this
static read does not settle in either direction — do not report it as settled
from here. The loader concatenates rather than merges, so a global and a
workspace hook with the same name both load and both fire; the "can never
shadow" in the comment is about the cloud root's path-id, not about name
collisions. This record goes stale if the global-roots expression drops the home
directory, if the subdirectory constant changes, or if the scan gains precedence
rules rather than concatenating.

---

## R-hookio-8 — Establish the symlink trap: the directory reader types a symlink as its own kind, and the loader keeps only plain files, so a symlinked hook is skipped with no warning

**Establishes:** two independent, individually reasonable behaviors combine into
a silent failure. **Half one:** the filesystem abstraction's `readDirectory`
reads entries with `withFileTypes: true` and classifies each as `"directory"`,
`"symlink"` or `"file"` — a symlink is typed `"symlink"`, **not** as whatever it
points at. **Half two:** the standalone hook loader filters
`entry.type === "file" && entry.name.endsWith(".json")`. A symlinked
`~/.kiro/hooks/foo.json` therefore matches neither branch of anything and is
dropped. **No log is emitted for a filtered entry** — the loader's six
diagnostics all fire on I/O or parse failures, and a filtered entry is neither.

**Why it matters:** the symptom is "my global hook does not work" with a clean
log, which is indistinguishable from "hooks are not firing at all" and from "the
workspace is untrusted" (R-hookio-9). Neither half is a bug alone —
`isSymbolicLink()` on a `Dirent` is the correct API and filtering to regular
files is defensive — which is why reading either half in isolation does not
predict the outcome. The operational consequence is a hard packaging invariant:
**hook JSON must be delivered as real regular files.** Any configuration manager
that materializes files as store symlinks silently produces zero hooks.

**Semantic anchor:** half one lives in the Node filesystem adapter. Its
`readDirectory` resolves the path, calls `readdir` with file types, and maps
each entry through an if/else-if/else assigning `"directory"` when
`isDirectory()`, `"symlink"` when `isSymbolicLink()`, and `"file"` otherwise,
returning `{name, type}` pairs; `ENOENT` becomes an empty array and any other
error propagates. Half two lives in the standalone hook loader's per-root
function: after existence and read checks (each with its own warning), it
filters the entries to those whose type is exactly the file string **and** whose
name ends with the JSON extension constant, maps to names, sorts, and loads
each. Between the filter and the load there is no logging of any kind.

**Verified against:** KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29.

**Command** (half one — the typing):

```bash
head -c $((14874400+560)) "$bundle" | tail -c 590
```

**Output at capture:**

```
 fs5.readdir(resolved, { withFileTypes: true });
          return entries.map((entry) => {
            let type;
            if (entry.isDirectory()) {
              type = "directory";
            } else if (entry.isSymbolicLink()) {
              type = "symlink";
            } else {
              type = "file";
            }
            return { name: entry.name, type };
          });
        } catch (error41) {
          if (error41.code === "ENOENT") {
            return [];
          }
          throw error41;
        }
      }
    };
  }
});

// ../../node_modules/ajv/dist/co<<<
```

**Command** (half two — the filter):

```bash
head -c $((13950319+130)) "$bundle" | tail -c 330
```

**Output at capture:**

```
       } catch (err) {
          this.deps.logger.warn("[hooks] Failed to read hooks directory", { hooksDir, err });
          return [];
        }
        const jsonFiles = entries.filter((entry) => entry.type === "file" && entry.name.endsWith(JSON_EXTENSION)).map((entry) => entry.name).sort();
        const loaded = [];
      <<<
```

**Command** (that no diagnostic covers the drop — every log site in the loader,
with its offset, so the gap around the filter at 13950319 is visible):

```bash
grep -boE 'logger\.(warn|info|debug|error)\("?\[?hooks[^,)]{0,45}' "$bundle" \
  | awk -F: '$1>13947485 && $1<13952600'
```

**Output at capture:**

```
13948863:logger.debug("hooks.load.workspaceRootOverlapsGlobal"
13949859:logger.warn("[hooks] Failed to stat hooks directory"
13950162:logger.warn("[hooks] Failed to read hooks directory"
13951130:logger.warn("[hooks] Failed to read hook file"
13951352:logger.warn("[hooks] Hook file is not valid JSON"
13951571:logger.warn("[hooks] Hook file does not match v2 schema"
```

**Six of six** loader diagnostics, and the filter at **13950319** sits between
the "Failed to read hooks directory" warning at 13950162 and the "Failed to read
hook file" warning at 13951130 with nothing in between. Every message names an
I/O or schema failure; none names a skipped entry.

**Positive controls:** the load-bearing claims are absences — no symlink
handling in the hook loader and no diagnostic for a filtered entry — so a re-run
must be able to tell "fixed" from "I can no longer parse this".

```bash
occ() { { grep -boF "$1" "$bundle" || true; } | wc -l; }
for s in 'isSymbolicLink()' 'withFileTypes: true' 'entry.type === "file"' \
         'type = "symlink"' 'entry.type === "symlink"' followSymlinks lstat \
         'hooks.load.skipped' 'hooks.load.symlink' 'not a regular file'; do
  printf '%-26s %s\n' "$s" "$(occ "$s")"
done
```

```
isSymbolicLink()           28
withFileTypes: true        27
entry.type === "file"      3
type = "symlink"           2
entry.type === "symlink"   1
followSymlinks             6
lstat                      54
hooks.load.skipped         0
hooks.load.symlink         0
not a regular file         0
```

The last three rows are the absences: no telemetry or log key exists for a
skipped entry, under any plausible spelling. The controls above them are
stronger than usual because they prove the bundle is **symlink-aware in
general** — 28 `isSymbolicLink()` calls, 6 `followSymlinks` options (in the
bundled file watcher), 54 `lstat` references, and **one** consumer that
explicitly handles the `"symlink"` type value by mapping it to a symlink
file-type bit. So the hook loader's silence is a local omission, not a bundle
that lacks the concept. The `entry.type === "file"` = 3 denominator matters too:
only one of the three is the hook loader; the other two are an unrelated
filename-matcher and a recursive file walker that _does_ have an else-if branch
for non-file entries.

**Notes:** the same abstraction's `stat` method has a `"symlink"` branch that is
**unreachable** — it calls `fs.stat`, which follows symlinks, so
`isSymbolicLink()` is always false there. Only `readDirectory`, using `Dirent`,
actually produces the symlink type, which is exactly why the trap is
directory-listing-specific: the loader's `exists` check on the hooks _directory_
succeeds, so a symlinked hooks **directory** behaves differently from a
symlinked hook **file**. This record does not establish what a symlinked hooks
_directory_ does — untested here. It goes stale in the good way if the filter
gains a `"symlink"` branch or the loader gains a skipped-entry log; check the
two absence rows first.

---

## R-hookio-9 — Establish the two gates on execution: workspace trust, and the one-shot re-entry guard on pre-tool-use

**Establishes:** two independent gates can stop a hook from running, and both
are quiet. **Trust:** hook execution requires the workspace to be trusted. The
gate exists twice — the module factory only populates its trigger table when
hooks are enabled _and_ the workspace is trusted (logging
`hooks.v2.executionDisabledUntrustedWorkspace` once at `info`), and the provider
re-checks it per call through a one-line predicate returning
`v2.workspaceTrusted`, logging `hooks.v2.executionSuppressedUntrusted` at
**debug** and returning empty. **Re-entry:** after a pre-tool-use hook produces
a message, the tool's name is pushed onto `skipHooksForNextToolCall`; the next
invocation of that same tool consumes the entry and skips pre-tool-use hooks
entirely, so the retried call cannot re-trigger the hook that intercepted it.

**Why it matters:** the two gates fail in opposite ways and both matter to a
loop. Untrusted-workspace silence is **indistinguishable from "hooks do not
fire"** — it is a debug-level log and an empty array, so a probe that concludes
"hooks are broken" may only have found an untrusted directory. This is one of
two independent causes of that same symptom (R-hookio-8 is the other), which is
precisely how a wrong conclusion survives a re-confirmation. The re-entry guard
is the reason a `PreToolUse` gate does not deadlock: the model is told the call
was intercepted, retries, and the retry is allowed through — meaning **an
interception delays a tool call, it does not prevent it**. A policy hook written
assuming its verdict is final is wrong; it gets exactly one shot per tool name.

**Semantic anchor:** the trust gate's per-call form is a two-line function
taking the hooks module and returning its `workspaceTrusted` field —
deliberately trivial so it can be called at several sites. It is called at five
places in the provider: hook extraction, the precomputed session-start path, the
single-hook execution path, and the pre-tool-use presence check. Three of those
log a suppression at debug with a `site:` discriminator naming which one fired.
The construction-time form is a ternary in the module factory: the object of
per-trigger entry points is built only when the feature flag and the trust flag
are both set. The re-entry guard is a graph-state annotation documented in place
as an array of tool names that should skip pre-tool-use hooks on their next
invocation, "to allow tool execution after hook interception (prevents infinite
hook loops)". Its consumer is the first statement of the session's pre-tool-use
executor: if the incoming tool id is in the list, return immediately with that
id **filtered out** — a one-shot consume — otherwise run the trigger; and at the
end, push the id if the hooks produced a message.

**Verified against:** KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29.

**Command** (the trust predicate, its call sites, and its log keys):

```bash
head -c $((19820420+90)) "$bundle" | tail -c 130
grep -boE 'executionAllowed\(v2\)' "$bundle"
grep -boE 'hooks\.v2\.execution[A-Za-z]*' "$bundle"
```

**Output at capture:**

```
mmand", command: h5.action.command }
  };
}
function executionAllowed(v2) {
  return v2.workspaceTrusted;
}
function createV2Hooks<<<
```

```
19820433:executionAllowed(v2)
19821067:executionAllowed(v2)
19821739:executionAllowed(v2)
19823724:executionAllowed(v2)
19826210:executionAllowed(v2)
```

```
13983857:hooks.v2.executionDisabledUntrustedWorkspace
19821113:hooks.v2.executionSuppressedUntrusted
19821785:hooks.v2.executionSuppressedUntrusted
19823770:hooks.v2.executionSuppressedUntrusted
```

Five call sites, four log keys: one `info` at construction and **three** debug
suppressions. The two call sites without a log are the predicate's own
definition line and the pre-tool-use presence check, which folds trust into a
boolean rather than logging.

**Command** (the construction-time gate):

```bash
head -c $((13983857+200)) "$bundle" | tail -c 380
```

**Output at capture:**

```
lemetry: deps.telemetry,
    processRunner: deps.processRunner,
    logger: deps.logger,
    homeDir: deps.homeDir
  };
  if (enabled && !workspaceTrusted) {
    deps.logger.info("hooks.v2.executionDisabledUntrustedWorkspace");
  }
  const triggers = enabled && workspaceTrusted ? {
    sessionStart: (input) => runSessionStartHooks(input, triggerDeps),
    stop: (input) => runSt<<<
```

**Command** (the re-entry guard — declaration with its shipped comment, the
consume, and the push):

```bash
head -c $((13666494+40)) "$bundle" | tail -c 220
head -c $((19826420+420)) "$bundle" | tail -c 460
grep -boF 'skipHooksForNextToolCall' "$bundle"
```

**Output at capture:**

```
Array of tool names that should skip pre-tool-use hooks on their next invocation
      // Used to allow tool execution after hook interception (prevents infinite hook loops)
      skipHooksForNextToolCall: Annotation(),<<<
```

```
.skipHooksForNextToolCall ?? [];
      if (skipList.includes(toolId)) {
        return {
          state: {
            ...state2,
            skipHooksForNextToolCall: skipList.filter((t) => t !== toolId)
          }
        };
      }
      const controller = new AbortController();
      const result = await v2.triggers.preToolUse({
        sessionId: state2.chatSessionId,
        cwd: workspaceRoot,
        signal: controller.signal,
        toolName: t<<<
```

```
13666494:skipHooksForNextToolCall
19813004:skipHooksForNextToolCall
19813146:skipHooksForNextToolCall
19816047:skipHooksForNextToolCall
19816091:skipHooksForNextToolCall
19826381:skipHooksForNextToolCall
19826523:skipHooksForNextToolCall
19827756:skipHooksForNextToolCall
```

**Eight occurrences, all classified.** Both provider bindings implement the same
guard, and there is no third:

| Offsets            | Site                                 | Role                                                                      |
| ------------------ | ------------------------------------ | ------------------------------------------------------------------------- |
| 13666494           | graph-state annotation               | declaration + shipped comment                                             |
| 19813004, 19813146 | ACP-delegating pre-tool-use executor | consume (read, then filter)                                               |
| 19816047, 19816091 | same executor, end of the hook loop  | push (one statement, two occurrences — reads the field and re-assigns it) |
| 19826381, 19826523 | in-process pre-tool-use executor     | consume (read, then filter)                                               |
| 19827756           | same executor, final statement       | push (one occurrence — reuses the already-bound `skipList`)               |

**Positive controls:** the absences here are "no trust _override_ exists" and
"no second re-entry mechanism".

```bash
occ() { { grep -boF "$1" "$bundle" || true; } | wc -l; }
for s in executionAllowed workspaceTrusted skipHooksForNextToolCall \
         'hooks.v2.executionSuppressedUntrusted' \
         allowUntrustedHooks trustOverride forceHooks skipTrustCheck \
         skipHooksForNextPrompt skipHooksOnce; do
  printf '%-40s %s\n' "$s" "$(occ "$s")"
done
```

```
executionAllowed                         5
workspaceTrusted                         51
skipHooksForNextToolCall                 8
hooks.v2.executionSuppressedUntrusted    3
allowUntrustedHooks                      0
trustOverride                            0
forceHooks                               0
skipTrustCheck                           0
skipHooksForNextPrompt                   0
skipHooksOnce                            0
```

First four rows are controls; last six are absences — the identifiers a trust
bypass or a second one-shot guard would plausibly have used, none of which
exists.

**Notes:** `workspaceTrusted` = 51 is a whole-bundle count and reaches far
beyond hooks (trust gates other subsystems too), so it is a control for
parseability, not a measure of the hook gate. Do not read the trust gate as
depth- or identity-related: it is a property of the _workspace_, and the
entirely separate `skipHooks` boolean that gates the prompt and stop graph nodes
is documented in R-nesting-3 of `concurrency-and-nesting.md` — conflating the
two is the most likely misreading of this record. The re-entry guard keys on
**tool name**, not on tool call or hook id, so two different pending calls to
the same tool share one skip entry; and it is scoped to pre-tool-use only, with
no equivalent for the prompt or stop triggers. This record goes stale if the
trust predicate gains conditions, if the suppression log rises above debug
(which would make the silent-failure note obsolete — a good outcome worth
recording), or if a bypass identifier starts returning hits.
