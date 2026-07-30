# Records: the workflow surface (Kiro CLI v3)

Eight replayable records covering the gate that switches Kiro's native workflow
engine on, why the shipped CLI never flips it, what the gate registers when it
does flip, and the node/enum/stop-condition contract those tools accept. All
captured against KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29.

## How to replay these

Resolve the bundle first. Several KAS versions were installed on the capture
machine (seven at capture time), so a glob that takes the first match silently
picks a stale one. The resolver refuses on ambiguity rather than guessing.

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
occ() { { grep -boF "$1" "$bundle" || true; } | wc -l; }
```

At capture `$bundle` was **20752757** bytes. Two records (R-workflow-3 and
R-workflow-8) also read the CLI client — the chat binary, which embeds the TUI's
JavaScript — as `$rustchat`; R-workflow-3 records how that path was resolved. At
capture it was **555372744** bytes.

Every command below was executed on 2026-07-29 in a `set -euETo pipefail` shell
in which `$bundle` (and `$rustchat`) already held the literal absolute paths,
and `occ` was defined as above. Substituting those names for the literal paths
is the only difference between what is printed here and what was typed; every
byte of every "output at capture" block is real, unedited output of the command
directly above it, with `<<<` marking where a fixed-size window truncates.

Six conventions that matter for replay:

- **Never `cat` either file.** The bundle is 20.8 MB and the client is 555 MB.
  Read a window with `head -c $((OFFSET+N)) "$bundle" | tail -c M`. That form is
  preferred over `tail -c +OFFSET | head -c N`, because the latter gives `head`
  a reason to close the pipe early and, under `pipefail`, the resulting SIGPIPE
  on `tail` **can** fail the whole command.

  **Correction, 2026-07-30:** that SIGPIPE failure did **not** reproduce when
  re-tested — see the full note in `concurrency-and-nesting.md`, which is the
  authoritative record for it. Keep using `head … | tail …`, but treat the
  preference as a portability hedge rather than an observed failure here.

- **Count occurrences as `{ grep -boF X f || true; } | wc -l`, never
  `grep -c`.** `grep -c` counts matching _lines_, and the capture machine's
  `grep` is **ugrep 7.5.0**, where `-c -o` counts occurrences instead — so the
  two forms disagree. The `-bo | wc -l` form is unambiguous on both, and the
  `|| true` keeps a legitimate zero from failing the pipeline.
- **The client's embedded JS needs `grep -a` and a `tr` filter.** It is binary,
  so `grep` must be told to treat it as text, and the surrounding bytes have no
  newlines: `tr -c '[:print:]\n' '.'` renders each non-printable byte as `.` so
  the window is readable.
- **Keep regexes narrow on the client.** A broad alternation over 555 MB
  exceeded ugrep's complexity limit and, in one case, ran past a two-minute
  timeout. Prefer several bounded `grep -aboF` calls.
- **Byte offsets in these records are conveniences, not anchors.** They move on
  every rebuild. The semantic anchor is the durable part.
- **A window that cuts mid-token is marked `<<<`.** The 27 command blocks in the
  records below (the resolver above is not counted) were each replayed and
  diffed against their recorded output on the capture day. **23 matched byte for
  byte.** Three differ in a way stated at the block: two windows truncate on a
  trailing space that markdown formatting strips, so those blocks are one space
  short, and one is a deliberately partial quote of a longer window. The
  remaining one, R-workflow-2's session-file count, reads live machine state and
  is expected to drift — that record says what it drifted to.

The bundle is not identifier-minified: it is esbuild-bundled but pretty-printed,
keeps `// src/<path>.ts` and `// ../acp-type-covenant/dist/<path>.js` section
markers, and keeps original names and comments. That makes the module marker
immediately preceding an offset the cheapest way to attribute a finding, and
several records below use it. The **client's** JS is genuinely minified (`qCe`,
`W0n`, `no`), so nothing there may be anchored on a name.

---

## R-workflow-1 — Establish that the workflow gate is one pure function resolving a client setting with a persisted fallback

**Establishes:** the entire workflow surface hangs off a single two-line pure
function that ORs a per-request client setting against a caller-supplied default
and floors at `false`:

```text
function resolveWorkflows(parsed2, persistedDefault) {
  return parsed2.data.workflows?.enabled ?? persistedDefault ?? false;
}
```

**Why it matters:** there is no server-side entitlement, no license check, no
account flag, and no handshake — the gate is data the caller hands in. That
makes the surface reachable by configuration alone, and it makes the whole
question "who supplies the second argument?" (R-workflow-2). It also means the
gate is resolved once per request and stored, not consulted continuously, so it
cannot be toggled mid-session.

**Semantic anchor:** inside the shared ACP type-covenant package's settings
module — the same file that defines `parseSettings` and the schema of accepted
setting keys — sits a family of five sibling resolvers, one per optional session
feature (semantic review, FTA, workflows, spec-plan, steering supervisor). Each
takes the parsed settings bag and an optional persisted default, and each is a
single `??` chain reading `parsed.data.<featureKey>?.enabled`. The workflow one
is third in source order, between FTA and spec-plan, and is the only member of
the family whose feature key is `workflows`. Nothing in the function touches the
network, the filesystem, or any account object.

**Verified against:** KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29.

**Drift:** 2.15.2 reproduced

**Command:**

```bash
grep -boE 'function resolve[A-Za-z]+\(parsed2, persistedDefault\)' "$bundle"
head -c $((868216+124)) "$bundle" | tail -c 133
```

**Output at capture:**

```
867954:function resolveSemanticReview(parsed2, persistedDefault)
868091:function resolveFta(parsed2, persistedDefault)
868207:function resolveWorkflows(parsed2, persistedDefault)
868335:function resolveSpecPlan(parsed2, persistedDefault)
869251:function resolveSteeringSupervisor(parsed2, persistedDefault)
```

```
function resolveWorkflows(parsed2, persistedDefault) {
  return parsed2.data.workflows?.enabled ?? persistedDefault ?? false;
}
funct<<<
```

**Command** (the module the function lives in, and that the server's
accepted-key schema really does include `workflows` — so a client that sent it
would be honoured):

```bash
{ grep -boE '^// \.\./acp-type-covenant/dist/[a-zA-Z0-9/._-]+' "$bundle" || true; } \
  | awk -F: '$1<868216' | tail -2
grep -boF 'BaseAgentSettingsSchema =' "$bundle"
head -c $((872016+11760)) "$bundle" | tail -c 11760 \
  | grep -oE '^      [a-zA-Z]+:' | tr -d ' :' | nl
```

**Output at capture:**

```
866565:// ../acp-type-covenant/dist/session/index.js
866939:// ../acp-type-covenant/dist/settings/index.js
```

```
872016:BaseAgentSettingsSchema =
```

```
     1	thinking
     2	tangentMode
     3	disableAutoCompaction
     4	codeIntelligence
     5	subagentOrchestration
     6	inlineAgents
     7	todoList
     8	checkpoint
     9	semanticReview
    10	fta
    11	goal
    12	workflows
    13	specPlan
    14	steeringSupervisor
    15	infraSafetyMonitor
    16	infraSafetyEnforce
    17	largeToolOutputHandler
    18	toolSearch
    19	knowledge
    20	sessionEviction
    21	compaction
```

**Denominator:** 21 accepted setting keys; `workflows` is one of them, at
position 12. `parseSettings` passes unknown keys through untouched
(`if (!schema2) { data2[key] = value; continue; }`), so an unrecognized key is
not an error — which is why sending `workflows` costs nothing even against a
build that dropped it.

**Positive controls:** not required — this record asserts a presence.

**Notes:** the `?? false` floor is why the feature reads as "off by default"
rather than "off unless explicitly disabled". This record goes stale if the `??`
chain gains a third source (an env read, an account object, a global default),
if the feature key is renamed away from `workflows`, or if the function stops
being pure.

---

## R-workflow-2 — Establish that only `session/load` can enable workflows, because only it passes the persisted fallback

**Establishes:** `resolveWorkflows` has exactly **two** production call sites
that create session state, and they differ in arity:

| Handler       | Call                                                                     | Second argument             |
| ------------- | ------------------------------------------------------------------------ | --------------------------- |
| `newSession`  | `resolveWorkflows(parsed2)`                                              | **none** — falls to `false` |
| `loadSession` | `resolveWorkflows(parsedSettings, persisted?.metadata.workflowsEnabled)` | the persisted metadata      |

So on a fresh session the only way in is a client-supplied
`_meta.kiro.settings.workflows`, and on a resumed session the persisted
`workflowsEnabled` is itself the fallback. **This is the enable path:** set
`"workflowsEnabled": true` in a persisted session's metadata and re-enter that
session.

**Why it matters:** it locates the whole enable question on disk instead of in
the client. The vendor's own doc comment on the persisted field says so outright
— the field exists precisely so a reload does not need the client to resupply
the setting. Combined with R-workflow-3 (the shipped client never supplies it),
the persisted route is not merely _a_ path, it is the **only** path available
without patching a binary.

**Semantic anchor:** the agent class exposes one ACP handler per session verb.
Both the create handler and the load handler open the same way — parse the
client's `_meta.kiro.settings`, then resolve each optional feature into a
`featureFlags` bag that is handed to session-state construction. In the
**create** handler every resolver is called with the parsed settings **only**.
In the **load** handler the same block is re-derived with a second argument read
off `persisted?.metadata.<feature>Enabled`. The persisted-metadata schema, in
the shared covenant package, declares `workflowsEnabled` as an optional boolean
with a doc comment naming the four workflow tools and stating the persistence
rationale. A third resolver cluster exists in a static config-template handler;
it creates no session and does not call the workflow resolver at all.

**Verified against:** KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29.

**Drift:** 2.15.2 relocated

**Command:**

```bash
grep -boE 'async (newSession|loadSession)\(' "$bundle"
grep -boE 'resolveWorkflows\([^)]*\)' "$bundle"
head -c $((20344566+42)) "$bundle" | tail -c 232
head -c $((20414152+88)) "$bundle" | tail -c 262
```

**Output at capture:**

```
19696919:async loadSession(
19800131:async loadSession(
20336663:async newSession(
20406904:async loadSession(
20681539:async loadSession(
```

```
868216:resolveWorkflows(parsed2, persistedDefault)
20344566:resolveWorkflows(parsed2)
20414152:resolveWorkflows(parsedSettings, persisted?.metadata.workflowsEnabled)
```

```
const parsed2 = parseSettings(kiroMeta?.settings);
    const semanticReviewEnabled = resolveSemanticReview(parsed2);
    const ftaEnabled = resolveFta(parsed2);
    const workflowsEnabled = resolveWorkflows(parsed2);
    const specP<<<
```

```
tings,
      persisted?.metadata.semanticReviewEnabled
    );
    const ftaEnabled = resolveFta(parsedSettings, persisted?.metadata.ftaEnabled);
    const workflowsEnabled = resolveWorkflows(parsedSettings, persisted?.metadata.workflowsEnabled);
    const specPl<<<
```

The one-arg site (20344566) falls between `async newSession(` (20336663) and
`async loadSession(` (20406904); the two-arg site (20414152) follows the load
handler. Five rows, four of them `loadSession`: three of those four are
unrelated interfaces in other modules, and the two ACP handlers are the pair in
`src/agent.ts`. Attribute by the preceding section marker rather than by
position:

```bash
{ grep -boE '^// src/[a-zA-Z0-9/._-]+' "$bundle" || true; } > /tmp/mods.txt
for o in 19696919 19800131 20336663 20406904 20681539; do
  printf '%-10s %s\n' "$o" "$(awk -F: -v o="$o" '$1<o' /tmp/mods.txt | tail -1)"
done
```

```
19696919   19690354:// src/session/session-persistence.ts
19800131   19798480:// src/session/session-message-store.ts
20336663   20224451:// src/agent.ts
20406904   20224451:// src/agent.ts
20681539   20678712:// src/session/bff-remote-session-source.ts
```

**Command** (the vendor's own statement of the enable path, on the persisted
field):

```bash
head -c $((857034)) "$bundle" | tail -c 366
```

**Output at capture:**

```
orchestration surface (bundled steering + the four
       * workflow tools) participates in this session. Defaults to disabled.
       * Persisted so a reloaded session keeps its choice without the client
       * having to resupply `_meta.kiro.settings.workflows` every time.
       */
      workflowsEnabled: external_exports2.boolean().optional(),
      /**
     <<<
```

**Command** (the client-settings shape, taken from the engine's own use of it —
the workflow-step-session builder enables the flag exactly this way):

```bash
head -c $((18644011+560)) "$bundle" | tail -c 900
```

**Output at capture:**

```
tories } : {},
          mcpServers: [],
          _meta: {
            kiro: {
              modeId: input.agentDefinition.id,
              // Workflow step sessions need the workflow tools (e.g. update_workflow
              // for status updates), but are created without client settings. Enable
              // the flag explicitly so resolveWorkflows returns true and the tools
              // are registered. createDefinitionForMode keys off `session.workflowId`
              // to give step sessions the completion protocol instead of the
              // orchestrator authoring steering.
              settings: { workflows: { enabled: true } },
              ...input.modelId ? { modelId: input.modelId } : {},
              ...input.effortLevel ? { effortLevel: input.effortLevel } : {},
              // Inherit the connection's already-resolved shell type so the step
              //<<<
```

**Command** (machine state on the capture host — the persisted key exists in
real session files, and is `false` in every one of them; this only counts key
presence, it does not read session content):

```bash
find "$HOME/.kiro" -name session.json -type f | wc -l
{ find "$HOME/.kiro" -name session.json -type f -exec grep -lF '"workflowsEnabled"' {} + || true; } | wc -l
{ find "$HOME/.kiro" -name session.json -type f \
    -exec grep -lE '"workflowsEnabled"[[:space:]]*:[[:space:]]*true' {} + || true; } | wc -l
```

The `|| true` on the last two is load-bearing under `pipefail`: `grep -l` exits
1 when it matches nothing, `find -exec` propagates that, and the third command
legitimately matches nothing.

**Output at capture:**

```
211
17
0
```

These first two numbers are **live machine state and drift.** Re-running the
same three commands about twenty minutes later during the same capture session
returned `212 / 18 / 0` — a new session had been created meanwhile. The first
two figures are context; the load-bearing figure is the third, and it is what a
replay should compare.

**Positive controls:** this record's load-bearing claim is an **absence** — no
second argument at the create site — so a control must show the method can see a
second argument when one exists.

```bash
grep -boE 'resolve(SemanticReview|Fta|Workflows|SpecPlan|SteeringSupervisor)\([^)]{0,60}\)' "$bundle"
```

```
867963:resolveSemanticReview(parsed2, persistedDefault)
868100:resolveFta(parsed2, persistedDefault)
868216:resolveWorkflows(parsed2, persistedDefault)
868344:resolveSpecPlan(parsed2, persistedDefault)
869260:resolveSteeringSupervisor(parsed2, persistedDefault)
20320230:resolveSpecPlan(parsedSettings)
20320319:resolveSemanticReview(parsedSettings)
20320376:resolveFta(parsedSettings)
20344461:resolveSemanticReview(parsed2)
20344516:resolveFta(parsed2)
20344566:resolveWorkflows(parsed2)
20344622:resolveSpecPlan(parsed2)
20344686:resolveSteeringSupervisor(parsed2)
20414063:resolveFta(parsedSettings, persisted?.metadata.ftaEnabled)
20414152:resolveWorkflows(parsedSettings, persisted?.metadata.workflowsEnabled)
```

Two things follow. The regex demonstrably renders a two-argument call in full
(rows 1-5, 14, 15), so a one-argument row is a real one-argument call and not a
truncation. And the create/load asymmetry is a **family-wide pattern**, not a
workflow-specific quirk: every sibling resolver is one-arg in the create handler
and two-arg in the load handler. If a re-run showed every row one-arg, the
persisted-fallback mechanism has been removed; if it showed every row two-arg,
`session/new` can enable workflows and this record is obsolete.

**Notes:** the third cluster (20320230-20320376) is `handleConfigTemplate`,
whose own doc comment says it "creates no session and registers no
`SessionState`, so nothing is persisted"; it does not call the workflow resolver
at all. Because resolution happens once per create/load, **the flag is immutable
for the life of the session** — there is no mid-session toggle, so every run
needs a pre-seeded session. On the capture host 17 of 211 persisted sessions
carry the key and none is `true`, so nothing here has actually exercised the
enabled path. This record goes stale if a third session-creating resolution
point appears, if the create handler starts passing a default, or if the
persisted metadata key is renamed.

---

## R-workflow-3 — Establish that the shipped CLI's session-settings builder omits the workflow key, which is why the surface looks dead

**Establishes:** the client's `_meta.kiro.settings` payload is built by one
function whose settable keys are a **fixed allowlist** — a nine-entry
`[configKey, settingKey]` table, two conditional pushes, a four-key defaults
object, plus hand-written `toolSearch` / `compaction` / `knowledge` blocks and a
one-row feature-to-setting table. **`workflows` appears in none of them**, and
no `chat.enableWorkflows` config key exists. The server would accept the key
(R-workflow-1); the client never sends it.

**Why it matters:** this is the whole reason the workflow engine reads as
unreachable. Nothing is disabled, gated, or entitled — the enabling field is
simply never populated on the wire, so `resolveWorkflows` sees `undefined` and
floors to `false` on every fresh session. It also explains why R-workflow-2's
persisted route is the only route: you cannot ask the shipped client to send the
setting, because there is no user-facing config key that maps to it.

**Semantic anchor:** in the client's embedded JS, the KAS client wrapper is
constructed with a `clientMeta` object literal, and one of its spread members is
the result of a zero-argument builder function invoked at construction time.
That builder reads the user's config store once, then assembles a settings
object from four sources in order: a defaults object of always-on capabilities;
an array of `[configKey, settingKey]` pairs it loops over, emitting
`{enabled: <bool>}` for each config value that is actually a boolean; two
`push`es onto that array guarded by an env var and by a feature check; and a set
of bespoke blocks for the settings that carry more than an `enabled` flag. It
ends by returning `undefined` when the object is empty and otherwise logging the
payload under a `[kas-settings]` tag. The builder is the only producer of
`clientMeta.settings`.

**Verified against:** KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29.

**Drift:** 2.15.2 changed — see `../drift-ledger.md`

**Command** (resolving the client binary; the resolver is Nix-store-shaped
because the capture machine installs kiro-cli through Nix, and the `case` arm
exists because `bin/kiro-cli-chat` there is a 218-byte wrapper script, not the
ELF):

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
grep -aboF '[kas-settings] Built settings for initialize' "$rustchat"
head -c $((396742110)) "$rustchat" | tail -c 829 | tr -c '[:print:]\n' '.'
```

**Output at capture:**

```
rustchat=/nix/store/qh137p3awp4dr0am6w4i49xjlj0mrp29-kiro-cli-2.15.1/bin/.kiro-cli-chat-wrapped
396743288:[kas-settings] Built settings for initialize
or(let[n,t]of W0n)if(no.isEnabled(n))e[t]={enabled:!0}}function qCe(){let e=wa(),n={},t={codeIntelligence:!0,knowledge:!0,thinking:!0,subagentOrchestration:process.env.KIRO_TEST_DISABLE_SUBAGENT_ORCHESTRATION!=="1"},a=[["chat.enableThinking","thinking"],["chat.enableKnowledge","knowledge"],["chat.enableCodeIntelligence","codeIntelligence"],["chat.enableTodoList","todoList"],["chat.enableCheckpoint","checkpoint"],["chat.enableTangentMode","tangentMode"],["chat.disableAutoCompaction","disableAutoCompaction"],["chat.enableSubagent","_subagent"],["chat.enableDelegate","_delegate"]];if(process.env.KIRO_INFRA_SAFETY_ROLLOUT_ENABLED==="1")a.push(["chat.enableInfraSafetyMonitor","infraSafetyMonitor"],["chat.enableInfraSafetyEnforce","infraSafetyEnforce"]);if(no.isEnabled("c2s"))a.push(["chat.enableC2s","c2s"]);for(let[s,A]of <<<
```

**Command** (where the result goes — `clientMeta`, which becomes `_meta.kiro`):

```bash
head -c $((396759400)) "$rustchat" | tail -c 800 | tr -c '[:print:]\n' '.'
```

**Output at capture** (the 800-byte window continues past `clientMeta` into
unrelated methods; `<<<` marks where this quotation stops, not where the window
does — the load-bearing part is the final spread `...s&&{settings:s}`, where `s`
is the builder's return value):

```
ies:[hM(),wM((A)=>this.handleUserInputRequest(A)),LCe(),...zCe()],clientMeta:{telemetryEnabled:Jw(),...Jw()&&{telemetry:Pw()},knowledge:!0,hooks:{enabled:!0,v2:!0},requirementsAnalysis:!0,...process.env.KIRO_INFRA_SAFETY_ROLLOUT_ENABLED==="1"&&{infrastructureSafety:!0},...s&&{settings:s}}})}sessionDisposables=[];retired=!1;assertActive(e){if(this.retired)throw Error(`KAS client closed during ${e}`)}<<<
```

**Positive controls:** the claim is an **absence inside a bounded region**, and
`workflows` occurs 41 times elsewhere in this 555 MB file — so a whole-file
count would prove nothing. The controls are therefore window-scoped: carve out
the builder and grep _that_.

```bash
echo "whole-file 'workflows' in client: $({ grep -aboF 'workflows' "$rustchat" || true; } | wc -l)"
w=$(mktemp)
head -c 396743320 "$rustchat" | tail -c 2100 > "$w"
for s in workflows chat.enableWorkflows codeIntelligence subagentOrchestration \
         toolSearch compaction memoryEnable knowledge; do
  printf '%-24s %s\n' "$s" "$({ grep -boF "$s" "$w" || true; } | wc -l)"
done
grep -oE '\["chat\.[A-Za-z]+","[_A-Za-z]+"\]' "$w"
rm -f "$w"
```

```
whole-file 'workflows' in client: 41
```

```
workflows                0
chat.enableWorkflows     0
codeIntelligence         2
subagentOrchestration    1
toolSearch               4
compaction               3
memoryEnable             1
knowledge                9
```

```
["chat.enableThinking","thinking"]
["chat.enableKnowledge","knowledge"]
["chat.enableCodeIntelligence","codeIntelligence"]
["chat.enableTodoList","todoList"]
["chat.enableCheckpoint","checkpoint"]
["chat.enableTangentMode","tangentMode"]
["chat.disableAutoCompaction","disableAutoCompaction"]
["chat.enableSubagent","_subagent"]
["chat.enableDelegate","_delegate"]
["chat.enableInfraSafetyMonitor","infraSafetyMonitor"]
["chat.enableInfraSafetyEnforce","infraSafetyEnforce"]
```

Six rows are the **controls**: setting names the same method finds inside the
same 2100-byte window, including `memoryEnable`, which reaches the payload only
through the feature-to-setting table. Two rows are the **absences**. The
pair-list is the denominator: **11 mappable config keys**, none of them a
workflow key. If a re-run reports every row `0`, the window has drifted off the
builder — re-locate it by the `[kas-settings]` log string first.

**Notes:** two of the eleven target keys (`_subagent`, `_delegate`) are
underscore-prefixed and are not among the server's 21 accepted keys, so the
allowlist is not even a subset of what the server takes; the mismatch is in the
client's favour on that axis and against it on `workflows`. This is a
**client-side omission**, not a removal: the payload shape the engine wants is
`{settings: {workflows: {enabled: true}}}` (R-workflow-2's step-session builder
uses exactly that), so any client that can inject `_meta.kiro.settings` can
enable the surface on a fresh session. This record goes stale the moment a
`chat.enableWorkflows` config key or a `["...","workflows"]` pair appears —
which is precisely the release that makes the persisted-metadata route
unnecessary.

---

## R-workflow-4 — Establish that workflow tool registration is all-or-nothing, and name every tool it registers

**Establishes:** one boolean gates the entire surface. When `workflowsEnabled`
is true the session gains **six** tools across three pools — `run_workflow`,
`inspect_workflow`, `update_workflow`, `validate_workflow` and `send_message` in
the chat pool, `validate_workflow` again in the spec pool, and the
workflow-creator's own `save_workflow_definition` in the custom-agent pool —
plus a bundled `workflows_default` steering document and a workflow
slash-command source. When it is false each pool array is `void 0`, and nothing
at all is registered.

**Why it matters:** it settles two things that would otherwise need probing.
First, there is no partial mode — you cannot get `run_workflow` without
`send_message`, which is why the mid-flight child-to-parent message channel is
unreachable on a normal launch and reachable the instant the flag flips. Second,
the gate is checked once at session-connection time and the arrays are spread
into the tool lists, so a `void 0` adds nothing; there is no later re-check to
catch.

**Semantic anchor:** during session-connection setup the agent constructs a
validate-workflow tool _conditionally_ on the resolved workflow flag, then
passes three optional arrays into the workspace-connection factory, grouped by
which tool pool they route into. Each array is a ternary on that same condition:
the chat array is a five-element literal (run, inspect, update, the
already-built validate instance, send-message), the spec array reuses the single
validate instance, and the custom-agent array holds the definition-saving tool.
A comment above the block states that _all_ workflow tools are gated on the
setting, singles out `send_message` and its cross-session messaging as the
reason, and notes that workflow step sessions always pass the gate because their
session builder sets the setting explicitly. On the consuming side each array is
spread with `?? []` into its pool, so absence is a no-op. Separately, the
session's steering list appends the bundled workflow steering when the flag is
set, and the slash-command registry adds a workflow command source whose
predicate reads the same per-session flag.

**Verified against:** KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29.

**Drift:** 2.15.2 relocated

**Command:**

```bash
grep -boF 'validateWorkflowTool' "$bundle"
head -c $((20479848+400)) "$bundle" | tail -c 700
head -c $((20482450)) "$bundle" | tail -c 1020
```

**Output at capture:**

```
20479848:validateWorkflowTool
20481952:validateWorkflowTool
20482154:validateWorkflowTool
20482272:validateWorkflowTool
20482296:validateWorkflowTool
```

```
box) {
        await sessionSandbox.dispose().catch(() => void 0);
        sessionSandbox = void 0;
      }
    }
    const broadcastOutbound = this.broadcastOutboundFor(sessionId);
    const sessionInfoEmitter = new SessionInfoEmitter((update) => broadcastOutbound.sessionUpdate(update));
    const validateWorkflowTool = workflowsEnabled ? this.workflowRuntime.createValidateWorkflowTool(workspacePaths) : void 0;
    const workspaceConnectionStartedAt = performance.now();
    const { workspace, executionLog, pendingChangesService, codeTool, dispose, acpToolApproval } = createACPWorkspaceConnection({
      connection: this.connection,
      sessionId,
      workspacePaths,
      machineId: "ac<<<
```

```
he workflows setting — including send_message, whose
      // cross-session messaging (and auto-wake behavior) must not be
      // reachable when workflows are disabled. Workflow step sessions
      // always pass this gate: createWorkflowStepSession sets
      // settings.workflows.enabled explicitly, so the step completion
      // protocol keeps its send_message signal. The same validate instance
      // goes into both the chat and spec pools (matching the pre-array
      // routing).
      workflowChatTools: validateWorkflowTool ? [
        this.workflowRuntime.createRunWorkflowTool(),
        this.workflowRuntime.createInspectWorkflowTool(),
        this.workflowRuntime.createUpdateWorkflowTool(),
        validateWorkflowTool,
        this.workflowRuntime.createSendMessageTool()
      ] : void 0,
      workflowSpecTools: validateWorkflowTool ? [validateWorkflowTool] : void 0,
      workflowCustomAgentTools: workflowsEnabled ? [this.workflowRuntime.createSaveWorkflowDefinitionTool(workspacePaths)]<<<
```

**Command** (the factory names map to these wire tool ids, and each pool array
has exactly one producer and one consumer — so there is no second registration
path):

```bash
grep -boE 'static id = "(run_workflow|inspect_workflow|update_workflow|validate_workflow|save_workflow_definition|send_message)"' "$bundle"
for s in workflowChatTools workflowSpecTools workflowCustomAgentTools; do
  printf '%s\n' "$s"; grep -boF "$s" "$bundle" | sed 's/^/  /'
done
head -c $((19308936+140)) "$bundle" | tail -c 280
```

**Output at capture:**

```
18268890:static id = "run_workflow"
18273883:static id = "inspect_workflow"
18281231:static id = "update_workflow"
18289032:static id = "validate_workflow"
18300611:static id = "save_workflow_definition"
18305910:static id = "send_message"
```

```
workflowChatTools
  19308936:workflowChatTools
  20481933:workflowChatTools
workflowSpecTools
  19311851:workflowSpecTools
  20482253:workflowSpecTools
workflowCustomAgentTools
  19314315:workflowCustomAgentTools
  20482334:workflowCustomAgentTools
```

```
atTools.push(codeTool);
      }
      if (introspectTool) {
        chatTools.push(introspectTool);
      }
      chatTools.push(...options.workflowChatTools ?? []);
      if (customAgentRegistry) {
        const inlineAgentsEnabled = isSettingEnabled(settings, "inlineAgents");
 <<<
```

**Command** (the two non-tool surfaces the same flag gates — steering and slash
commands):

```bash
head -c $((20402053)) "$bundle" | tail -c 200
head -c $((20271700)) "$bundle" | tail -c 200
```

**Output at capture:**

```
cSteering] : session.globalSteering;
    const steering = session.workflowId ? [...baseSteering, WORKFLOW_STEP_COMPLETION_PROTOCOL] : session.workflowsEnabled ? [...baseSteering, workflows_default] : <<<
```

```
 is registered (see hydrate/create ordering).
      createWorkflowCommandSource((sessionId) => this.sessionState(sessionId)?.workflowsEnabled ?? false),
      createGoalCommandSource(() => isSettingEn<<<
```

**Positive controls:** the absence claim here is "nothing is registered when the
flag is false", which is established structurally by the ternaries rather than
by a grep for a missing string. The load-bearing grep-based claim is the **two
hits per pool array** — one producer, one consumer — and its control is that all
three arrays return exactly 2, from the same method, in the same run. A future
re-run reporting 0 for all three has lost the plumbing; reporting 3+ means a
second registration path exists and the all-or-nothing claim needs re-checking.

**Notes:** the `validateWorkflowTool` variable is deliberately the condition for
two of the three ternaries (its truthiness _is_ the flag), while the third tests
`workflowsEnabled` directly — different expressions, same boolean. The persisted
metadata's doc comment (R-workflow-2) says "**the four** workflow tools", which
is already stale against this block's five-plus-one; treat the comment as
documentation drift, not as a second contract. `send_message`'s appearance here
is the mechanical reason a plain subagent cannot use it: the tool is never
registered outside this gate. This record goes stale if a pool array gains a
second consumer, if any tool moves out of the ternaries, or if the ternary
condition is split per-tool.

---

## R-workflow-5 — Establish the node, join-policy, iteration and status enums, verbatim, and the validator's structural ceilings

**Establishes:** the workflow contract's enums, quoted exactly:

```text
WorkflowStatusSchema = external_exports2.enum(["running", "paused", "completed", "failed", "aborted"]);
NodeStatusSchema = external_exports2.enum(["pending", "running", "paused", "completed", "failed", "aborted", "skipped"]);
NodeTypeSchema = external_exports2.enum(["step", "sequence", "repeat", "parallel", "watch"]);
JoinPolicySchema = external_exports2.enum(["all", "allSettled", "any"]);
OnMaxIterationsSchema = external_exports2.enum(["abort", "continue", "pause"]);
WatchOutcomeSchema = external_exports2.enum(["idle", "new-activity", "terminal-state"]);
```

with `MAX_REPEAT_ITERATIONS = 1e3` bounding `repeat.maxIterations`, and two
further per-workflow ceilings in the validator: `DEFAULT_MAX_NESTING_DEPTH = 8`
and `DEFAULT_MAX_STEP_NODES = 20`.

**Why it matters:** the five node types plus these three numbers are the entire
scheduling vocabulary available, and the **20-step-node ceiling** is the one
most likely to bite a design: a drain built as K parallel self-draining `repeat`
branches spends one step node per branch and cannot exceed 20 in total. The
join-policy values matter because they determine what happens to siblings, and
that is where this record makes a correction (below).

**Semantic anchor:** the shared covenant package has a workflow-capability types
module whose initializer declares, in one run, six string enums — run status,
node status, node type, join policy, max-iterations behavior, watch outcome —
followed by the file-check and stop-condition object schemas and the
repeat-iteration ceiling. Immediately after, a discriminated union of node
schemas keys on a `type` literal per node kind; the repeat member bounds its
iteration count by that ceiling and carries a refinement forbidding both stop
forms at once, and the parallel member's only extra field is the join policy.
Separately, the engine's own workflow validator module opens with three default
limits — nesting depth, step-node count, and repeat iterations aliased to the
covenant ceiling — bundled into a defaults record, and the validate tool's
description recites the first two to the model.

**Verified against:** KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29.

**Drift:** 2.15.2 relocated

**Command:**

```bash
grep -boE '(WorkflowStatusSchema|NodeStatusSchema|NodeTypeSchema|JoinPolicySchema|OnMaxIterationsSchema|WatchOutcomeSchema|FileCheckSchema|StopConditionSchema|MAX_REPEAT_ITERATIONS) =' "$bundle"
head -c $((816530)) "$bundle" | tail -c 594
head -c $((817177+29)) "$bundle" | tail -c 29
head -c $((819135)) "$bundle" | tail -c 110
grep -boE 'DEFAULT_MAX_(NESTING_DEPTH|STEP_NODES) = [0-9]+' "$bundle"
```

**Output at capture:**

```
815936:WorkflowStatusSchema =
816044:NodeStatusSchema =
816170:NodeTypeSchema =
816268:JoinPolicySchema =
816345:OnMaxIterationsSchema =
816429:WatchOutcomeSchema =
816522:FileCheckSchema =
816704:StopConditionSchema =
817177:MAX_REPEAT_ITERATIONS =
17327601:MAX_REPEAT_ITERATIONS =
```

```
WorkflowStatusSchema = external_exports2.enum(["running", "paused", "completed", "failed", "aborted"]);
    NodeStatusSchema = external_exports2.enum(["pending", "running", "paused", "completed", "failed", "aborted", "skipped"]);
    NodeTypeSchema = external_exports2.enum(["step", "sequence", "repeat", "parallel", "watch"]);
    JoinPolicySchema = external_exports2.enum(["all", "allSettled", "any"]);
    OnMaxIterationsSchema = external_exports2.enum(["abort", "continue", "pause"]);
    WatchOutcomeSchema = external_exports2.enum(["idle", "new-activity", "terminal-state"]);
    FileChec<<<
```

```
MAX_REPEAT_ITERATIONS = 1e3;
```

```
s2.number().int().positive().max(MAX_REPEAT_ITERATIONS),
        stopCondition: StopConditionSchema.optional()<<<
```

```
17327525:DEFAULT_MAX_NESTING_DEPTH = 8
17327560:DEFAULT_MAX_STEP_NODES = 20
```

**A correction this record makes.** Two claims commonly attached to
`joinPolicy: "any"` — that the tool description never states its semantics, and
that whether it cancels or orphans its siblings is therefore an open question
needing a live probe — are **both wrong**, and the second is answerable
statically.

The semantics _are_ documented, just not in the tool whose description people
read. The `run_workflow` description (in the run-workflow tool module) lists the
three values and stops; the **workflow-creator bundled agent's** steering, in
the bundled-agents module, spells all three out:

```bash
head -c $((18266388+340)) "$bundle" | tail -c 480
head -c $((17966140)) "$bundle" | tail -c 420
```

```
, "steps": [Node, ...] }

4. parallel \u2014 Runs branches concurrently.
   { "type": "parallel", "id": "par-id", "branches": [Node, ...], "joinPolicy": "all" | "allSettled" | "any" }

5. watch \u2014 Polls an external system (non-LLM).
   { "type": "watch", "id": "watch-id", "handler": "github-pr", "config": {} }

TEMPLATE VARIABLES:
Use {{variable_name}} in prompts to interpolate input values. Step outputs are available as {{step_id.output}} and {{previous.output}}.

MODEL <<<
```

The second window's output contains a literal triple-backtick sequence, so it is
fenced with four backticks here:

````
often a step or sequence).\n\n```json\n{ "type": "parallel", "id": "par-id", "branches": [Node, ...], "joinPolicy": "all" | "allSettled" | "any" }\n```\n\n- `all`: all branches must succeed. First failure aborts siblings.\n- `allSettled`: wait for all branches regardless of individual failures.\n- `any`: first branch to complete wins; abort the rest.\n\n### 5. watch\n\nPolls an external system (non-LLM). Used inside <<<
````

And the scheduler confirms it in code rather than in prose. Each branch gets its
own `AbortController`; `joinAny` aborts every sibling controller the moment one
branch reports `completed`:

```bash
grep -boE 'async function join(All|AllSettled|Any)\(' "$bundle"
head -c $((17349099+1250)) "$bundle" | tail -c 1300
head -c $((17351914+960)) "$bundle" | tail -c 975
```

```
17350800:async function joinAll(
17351783:async function joinAllSettled(
17351914:async function joinAny(
```

```
 {
      walk(node.branches, visit);
    }
  }
}

// src/workflow/parallel-scheduler.ts
async function scheduleParallel(request2) {
  const { joinPolicy, branches, signal: signal2 } = request2;
  const branchControllers = branches.map(() => new AbortController());
  const onOuterAbort = () => {
    for (const c5 of branchControllers) {
      if (!c5.signal.aborted) c5.abort();
    }
  };
  if (signal2.aborted) {
    onOuterAbort();
  } else {
    signal2.addEventListener("abort", onOuterAbort, { once: true });
  }
  const results = branches.map((b5) => ({ branchId: b5.branchId, outcome: "aborted" }));
  const promises6 = branches.map((branch, idx) => runBranchSafely(branch, branchControllers[idx], results, idx));
  let outcome;
  try {
    switch (joinPolicy) {
      case "all":
        outcome = await joinAll(promises6, branchControllers, results);
        break;
      case "allSettled":
        outcome = await joinAllSettled(promises6, results);
        break;
      case "any":
        outcome = await joinAny(promises6, branchControllers, results);
        break;
    }
  } finally {
    signal2.removeEventListener("abort", onOuterAbort);
  }
  return { joinPolicy, results, outcome };
}
async function runBranchSafely(branch, controller, results, idx) {
  try {
    const settleme<<<
```

```
ts(results);
}
async function joinAny(promises6, controllers, results) {
  return await new Promise((resolve24) => {
    let pending = promises6.length;
    if (pending === 0) {
      resolve24("failed");
      return;
    }
    let resolved = false;
    promises6.forEach((p2, idx) => {
      void p2.finally(() => {
        if (resolved) return;
        if (results[idx].outcome === "completed") {
          resolved = true;
          for (let i5 = 0; i5 < controllers.length; i5 += 1) {
            if (i5 !== idx && !controllers[i5].signal.aborted) {
              controllers[i5].abort();
            }
          }
          void (async () => {
            await Promise.allSettled(promises6);
            resolve24("completed");
          })();
          return;
        }
        pending -= 1;
        if (pending === 0) {
          resolved = true;
          resolve24(results.some((r5) => r5.outcome === "paused") ? "paused" : "failed");
        }
      });
    });
```

So **`any` cancels; it does not orphan.** First-completion resume destroys
in-flight sibling work, which means a drain must not use `any` as a
first-completion trigger — the only safe drain shape over `parallel` is
independent self-draining branches under `all`. That was the right instinct for
the wrong reason: not because the semantics were unknown, but because they are
known and hostile. A live probe of `any` is still worth running to confirm the
abort actually stops the model turn (this record covers only what the scheduler
_requests_ — an `AbortController.abort()` is not by itself proof that an
in-flight agent turn halts), but it is a confirmation, not a discovery.

**Positive controls:** not required — this record asserts presences. Its one
absence-shaped element (no fourth join policy, no sixth node type) is bounded by
the enum literals themselves, which are the denominator.

**Notes:** `NodeStatusSchema` carries `skipped`, which the run-status enum does
not, so a node can be skipped while no run ever is. `onMaxIterations: "pause"`
is a trap and the engine's own description says why — resuming does not grant
more iterations, so the loop re-pauses immediately, and a paused run cannot be
retried (retry applies only to `completed`/`failed`/`aborted`). The bundled
`ralph` and `goal` recipes both ship with `"pause"` (R-workflow-7). Use
`"abort"`, or size `maxIterations` correctly up front. This record goes stale if
any enum gains or loses a member, if either validator ceiling changes, or if
`joinAny` stops aborting siblings — the last of which would _open_ a root-driven
drain shape that is currently closed.

---

## R-workflow-6 — Establish the stop-condition schema and record that its third field is absent from both tool descriptions

**Establishes:** `StopConditionSchema` has **three** optional fields and a
refinement requiring at least one:

```text
StopConditionSchema = external_exports2.object({
  containsText: external_exports2.string().optional(),
  fileCheck: FileCheckSchema.optional(),
  completionSignal: external_exports2.enum(["success", "need_input", "error"]).optional()
}).refine((v2) => v2.containsText !== void 0 || v2.fileCheck !== void 0 || v2.completionSignal !== void 0, {
  message: "StopCondition requires at least one of containsText, fileCheck, or completionSignal"
});
```

`completionSignal` is fully implemented — it is the **first** branch the
evaluator tests — and a bundled recipe uses it. It is **absent from both
description surfaces the model reads**, each of which documents the type as
`{ containsText?, fileCheck? }`. That is schema/description drift, and it is
recorded here as drift rather than as a feature to rely on.

**Why it matters:** a stop condition is how a `repeat` loop terminates, so its
field set is the termination vocabulary. The drift cuts both ways: a design that
plans around `completionSignal` is relying on an undocumented field that could
be withdrawn as a doc fix, while a design that believes the description is
missing a working, shipped termination mode. The same schema also silently
relaxes a rule the descriptions state absolutely — see the second correction
below.

**Semantic anchor:** the workflow types module defines a file-check object
(path, JSON path, expected value) and then a stop-condition object with three
optional members, closed by a refinement whose message enumerates all three. The
engine's stop-condition module holds an async evaluator that short-circuits
through those same three members **in schema order** — completion signal,
contains-text, file-check — each guarded by an `!== void 0` presence test; the
completion-signal helper compares an expected enum value against the most recent
signal recorded on the evaluation context and returns false when none has been
seen. Two separate prose surfaces describe the type to the model: the
`run_workflow` tool's own description, and the bundled workflow-creator agent's
authoring steering. Both recite a two-field shape.

**Verified against:** KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29.

**Drift:** 2.15.2 relocated

**Command:**

```bash
head -c $((817160)) "$bundle" | tail -c 640
echo "occurrences of completionSignal: $(occ completionSignal)"
head -c $((17269920+560)) "$bundle" | tail -c 580
grep -boE 'function evaluateCompletionSignal\(' "$bundle"
head -c $((17272050+330)) "$bundle" | tail -c 340
```

**Output at capture:**

```
  FileCheckSchema = external_exports2.object({
      path: external_exports2.string(),
      jsonPath: external_exports2.string(),
      value: external_exports2.unknown()
    });
    StopConditionSchema = external_exports2.object({
      containsText: external_exports2.string().optional(),
      fileCheck: FileCheckSchema.optional(),
      completionSignal: external_exports2.enum(["success", "need_input", "error"]).optional()
    }).refine((v2) => v2.containsText !== void 0 || v2.fileCheck !== void 0 || v2.completionSignal !== void 0, {
      message: "StopCondition requires at least one of containsText, fileCheck, or completionSig<<<
```

```
occurrences of completionSignal: 37
```

```
ion evaluateStopCondition(condition, context3) {
  if (condition.completionSignal !== void 0 && evaluateCompletionSignal(condition.completionSignal, context3)) {
    return true;
  }
  if (condition.containsText !== void 0 && evaluateContainsText(condition.containsText, context3)) {
    return true;
  }
  if (condition.fileCheck !== void 0 && await evaluateFileCheck(condition.fileCheck, context3)) {
    return true;
  }
  return false;
}
async function evaluateStopWhen(stopWhen, context3) {
  const result = parseStopWhen(stopWhen);
  if (!result.ok) {
    throw new StopCond<<<
```

```
17272050:function evaluateCompletionSignal(
```

```
text3);
}
function evaluateCompletionSignal(expected, context3) {
  if (context3.mostRecentCompletionSignal === void 0) {
    return false;
  }
  return context3.mostRecentCompletionSignal === expected;
}
function evaluateContainsText(needle, context3) {
  if (context3.mostRecentCapturedOutput === null) {
    return false;
  }
  return co
<<<
```

**Command** (the drift — both description surfaces, and a bundled recipe using
the undocumented field anyway):

```bash
head -c $((17965191+120)) "$bundle" | tail -c 121
head -c $((18265874+118)) "$bundle" | tail -c 119
head -c $((17556112+30)) "$bundle" | tail -c 62
```

**Output at capture:**

```
`stopCondition`: `{ containsText?: string, fileCheck?: { path, jsonPath, value } }` (at least one field required)\n- `sto<<<
```

```
 stopCondition: { containsText?: string, fileCheck?: { path, jsonPath, value } } (at least one field required)
   - sto<<<
```

```
"pause",
      stopCondition: { completionSignal: "success" },
```

**Positive controls:** the load-bearing claim is an **absence inside two bounded
regions**, and `completionSignal` occurs 37 times bundle-wide, so a whole-file
count proves nothing. Carve each description module out by its section markers
and grep the carving:

```bash
for spec in "A:src/bundled-agents/index.ts:17900547:17990733" \
            "B:src/tools/run-workflow.ts:18262009:18272584"; do
  IFS=: read -r tag mod from to <<<"$spec"
  w=$(mktemp); head -c "$to" "$bundle" | tail -c $((to-from)) > "$w"
  printf 'surface %s (%s), %s bytes\n' "$tag" "$mod" "$(stat -c %s "$w")"
  for s in stopCondition containsText fileCheck jsonPath completionSignal \
           onMaxIterations joinPolicy; do
    printf '  %-18s %s\n' "$s" "$({ grep -boF "$s" "$w" || true; } | wc -l)"
  done
  rm -f "$w"
done
```

```
surface A (src/bundled-agents/index.ts), 90186 bytes
  stopCondition      10
  containsText       1
  fileCheck          5
  jsonPath           4
  completionSignal   0
  onMaxIterations    8
  joinPolicy         4
surface B (src/tools/run-workflow.ts), 10575 bytes
  stopCondition      5
  containsText       1
  fileCheck          3
  jsonPath           3
  completionSignal   0
  onMaxIterations    4
  joinPolicy         1
```

Six control rows per surface show the method reading each module's prose
successfully — `containsText` and `fileCheck`, the two fields that _are_
documented, are found in both — while `completionSignal` is 0 in both. A re-run
where the controls also collapse to 0 has lost the module boundaries; re-derive
them from the `// src/` markers first.

**A second correction, on the same schema.** Both descriptions state that a
`repeat` must supply "Exactly ONE of stopCondition or stopWhen ... (not both,
not neither)". The schema and the validator enforce only the **both** half:

```bash
grep -boE '(at most one|Exactly ONE|exactly one)[^"]{0,80}' "$bundle" \
  | grep -iE 'stopcondition|stopwhen'
v=$(mktemp); head -c 17349099 "$bundle" | tail -c $((17349099-17327428)) > "$v"
{ grep -oE '`[A-Z][^`]{5,88}' "$v" || true; } | head -30
rm -f "$v"
```

```
820314:at most one of stopCondition or stopWhen
821400:at most one of stopCondition or stopWhen
17965401:Exactly ONE of stopCondition or stopWhen must be provided (not both, not neither).\n\n### 3
18264854:exactly one of stopCondition or stopWhen.
18266079:Exactly ONE of stopCondition or stopWhen must be provided (not both, not neither).
```

```
`Workflow exceeds the maximum nesting depth of ${limit}.
`Workflow has ${count} step nodes, exceeding the maximum of ${limit}.
`Repeat '${nodeId}' has maxIterations=${value}, exceeding the maximum of ${limit}.
`Step '${nodeId}' must define at least one of \
`Repeat '${nodeId}' has an invalid stopWhen='${stopWhen}': ${detail}
`Duplicate node id '${nodeId}' in workflow; ids must be unique.
`Node '${nodeId}' has a fileCheck path '${path61}' that ${resolves}outside the allowed wor
`Repeat '${node.id}' must not define both stopCondition and stopWhen.
`Step '${nodeId}' references ${token} from inside a parallel branch, which has no guarante
`Step '${nodeId}' references ${token} but has no prior sibling step to read output from.
`Step '${nodeId}' references ${token} but no node with id '${targetId}' exists in the work
`Step '${nodeId}' references ${token} but node '${targetId}' produces no captured output.
`Step '${nodeId}' references ${token} but node '${targetId}' does not run before it.
`Step '${nodeId}' references ${token} but no step declares an artifact named '${reference.
`Step '${nodeId}' references ${token} but no step declaring artifact '${reference.name}' (
`Node '${ownerId}' references ${token} in a stop/completion condition, which has no previo
`Node '${ownerId}' references ${token} but no node with id '${targetId}' exists in the wor
`Node '${ownerId}' references ${token} but node '${targetId}' produces no captured output.
`Node '${ownerId}' references ${token} but node '${targetId}' does not run before it.
`Node '${ownerId}' references ${token} but no step declares an artifact named '${reference
`Node '${ownerId}' references ${token} but no step declaring artifact '${reference.name}'
```

The schema refinement says **"at most one"** (twice), the validator's only
related message is **"must not define both"**, and no "requires one of
stopCondition or stopWhen" message exists anywhere. **Denominator: 21 validator
messages, 1 touching this rule.** The 20 siblings listed alongside it are the
positive controls: the same extraction finds every other rule this module
enforces, so the missing rule is missing, not unparsed. A `repeat` with
**neither** stop form is therefore structurally accepted and will run to
`maxIterations`, where `onMaxIterations` decides the outcome. That is a viable
bounded-iteration loop, and it is only reachable because the description
overstates the rule. Static read only — a live run would confirm the loop is not
rejected at submit time.

**Notes:** `completionSignal` being evaluated **first** matters: a condition
that sets both it and a file check will fire on the signal without ever reading
the file. `evaluateCompletionSignal` returns false when no signal has been
recorded, so a signal-only condition on a step that emits none never fires, and
the loop runs to `maxIterations`. This record goes stale if `completionSignal`
is removed, if it gains description coverage (at which point the drift is closed
and this record becomes a historical note), or if a "neither" rejection appears
in the validator.

---

## R-workflow-7 — Establish the bundled recipe set at seven, and reproduce the iterative-loop recipe verbatim

**Establishes:** exactly **seven** workflow recipes ship in the bundle —
`autoresearch`, `feature-pipeline`, `goal`, `investigate`, `publish-pr`,
`ralph`, `semantic-review-multi-model` — registered in a single id-to-object
table and exposed as `bundled://<id>`. The iterative-loop recipe, `ralph`, is a
**sequential** drain: one `repeat` wrapping one `step`, terminated by a JSON
file check, capped at 200 iterations with `onMaxIterations: "pause"`.

**Why it matters:** `bundled://ralph` is the cheapest possible smoke test of the
enable path (R-workflow-2), because it needs no authored workflow JSON — so a
failure separates "the flag did not take" from "my definition is wrong". It is
_not_ a concurrency test: it contains no `parallel` node, so it validates
`repeat` + `fileCheck` + durable mid-run progress and nothing about draining.
The recipe is also the clearest existing statement of the shipped loop idiom:
durable state in a file the human can inspect, one item per iteration, the model
updating the file rather than the engine tracking progress.

**Semantic anchor:** each recipe is an esbuild-inlined JSON module, so each
appears as a `// src/bundled-workflows/<name>.workflow.json` marker followed by
a `var <name>_workflow_default = { ... }` object literal. An index module
immediately after them declares one array of `[id, object]` pairs and eagerly
parses every entry against the workflow schema at load, logging a parse failure
per id and warning when an object's own `name` disagrees with its registry id.
Each parsed entry is republished with a `source` of `bundled://<id>`, its
declared inputs, and a precomputed node plan. A separate accessor returns a copy
of that list, and the `run_workflow` tool interpolates the recipe names into its
own description.

**Verified against:** KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29.

**Drift:** 2.15.2 relocated

**Command:**

```bash
echo "recipes: $({ grep -boE '// src/bundled-workflows/[a-z0-9-]+\.workflow\.json' "$bundle" || true; } | wc -l)"
grep -boE '// src/bundled-workflows/[a-z0-9.-]+' "$bundle"
head -c $((17571106+430)) "$bundle" | tail -c 432
```

**Output at capture:**

```
recipes: 7
```

```
17544034:// src/bundled-workflows/autoresearch.workflow.json
17544900:// src/bundled-workflows/feature-pipeline.workflow.json
17555460:// src/bundled-workflows/goal.workflow.json
17557803:// src/bundled-workflows/investigate.workflow.json
17558904:// src/bundled-workflows/publish-pr.workflow.json
17559963:// src/bundled-workflows/ralph.workflow.json
17561165:// src/bundled-workflows/semantic-review-multi-model.workflow.json
17571003:// src/bundled-workflows/index.ts
```

```
earch_workflow_default],
  ["feature-pipeline", feature_pipeline_workflow_default],
  ["goal", goal_workflow_default],
  ["investigate", investigate_workflow_default],
  ["publish-pr", publish_pr_workflow_default],
  ["ralph", ralph_workflow_default],
  ["semantic-review-multi-model", semantic_review_multi_model_workflow_default]
];
var parsed = parseAll();
function parseAll() {
  const out = [];
  for (const [id, raw] of BUNDLE<<<
```

**Denominator:** eight `// src/bundled-workflows/` markers, of which one is
`index.ts` — hence **7 recipes**, and the registry array lists the same 7. Both
counts must agree; if they diverge, a recipe file shipped without being
registered or vice versa.

**Command** (the iterative-loop recipe, verbatim):

```bash
head -c $((17561160)) "$bundle" | tail -c 1195
```

**Output at capture:**

```
 src/bundled-workflows/ralph.workflow.json
var ralph_workflow_default = {
  name: "ralph",
  description: "Loops a single coding agent against a goal, working through a JSON checklist one item at a time until every item is done. Suits decomposable work driven by a JSON checklist file: progress is durable and human-inspectable mid-run. For a single non-decomposable outcome, use the goal recipe instead.",
  inputs: { goal: "prompt", prd_path: "file" },
  steps: [
    {
      type: "repeat",
      id: "ralph-loop",
      maxIterations: 200,
      onMaxIterations: "pause",
      stopCondition: { fileCheck: { path: "{{prd_path}}", jsonPath: "complete", value: true } },
      steps: [
        {
          type: "step",
          id: "iterate",
          agent: "wf-coder",
          prompt: 'Goal: {{goal}}\n\nRead {{prd_path}}. If the file does not exist, create it as a JSON checklist that breaks down the goal into implementable items (each with a "done" field) and a top-level "complete": false. If it already exists, pick the first unchecked item, implement it, run tests, commit. Update {{prd_path}} to mark it done. Set complete: true when nothing remains.'
        }
      ]
    }
  ]<<<
```

**Command** (the `bundled://` source form and the run tool's returns-immediately
contract):

```bash
head -c $((17572044+300)) "$bundle" | tail -c 560
head -c $((18262976+200)) "$bundle" | tail -c 620
```

**Output at capture:**

```
e !== id) {
      logger.warn("bundled_workflows.id_mismatch", { id, workflowName: parseResult.data.name });
    }
    out.push({
      name: id,
      ...parseResult.data.description !== void 0 && { description: parseResult.data.description },
      source: `bundled://${id}`,
      workflow: parseResult.data,
      inputs: parseResult.data.inputs,
      plan: buildNodePlan(parseResult.data.steps)
    });
  }
  return out;
}
function getBundledWorkflows() {
  return [...parsed];
}

// src/session/execution-message-adapter.ts
import * as crypto16 from "cr<<<
```

```
xternal_exports2.unknown()).optional().nullable().describe("Inline workflow object. Mutually exclusive with `workflowPath`."),
  inputs: external_exports2.record(external_exports2.string()).optional().default({}).describe("Input values for the workflow template variables.")
});
var BUNDLED_RECIPE_NAMES = getBundledWorkflows().map((w) => w.name).join(", ");
var RUN_WORKFLOW_DESCRIPTION = `Starts a workflow recipe and returns immediately. Provide exactly one of workflowPath or an inline workflow object, plus input values.

WORKFLOWPATH FORMS:
- "bundled://<name>" \u2014 runs a recipe shipped with the agent. Bundled<<<
```

**Positive controls:** not required — this record asserts a presence and a
count, both with their denominators stated above.

**Notes:** `ralph` ships with `onMaxIterations: "pause"`, which R-workflow-5
flags as a trap (a paused run cannot be retried and resuming grants no further
iterations); `goal` ships the same way. So the vendor's own long-loop recipes
use the setting a custom drain should avoid — do not copy that field from them.
The `step` node here names `agent: "wf-coder"`, a bundled workflow agent;
whether a user-authored agent can fill an `agent` slot is not settled by this
record and needs a live check. This record goes stale if the count changes, if a
recipe is renamed (the registry id, not the object's `name`, is what
`bundled://` resolves), or if `ralph` gains a `parallel` node — at which point
it _would_ become a concurrency test.

---

## R-workflow-8 — Establish the negative: no environment variable enables the workflow gate, and the one that claims to has no reader

**Establishes:** across the 20.8 MB engine bundle there are **180**
`process.env` occurrences — **63** distinct dot-form names and **52** distinct
bracket-form subscripts — and **zero** of either matches `work` or `flow`
case-insensitively. The engine's feature-flag mechanism is likewise clean:
**10** distinct `isFeatureEnabled("...")` keys, none of them `workflows`.

**The correction:** the claim "no env var exists" is true **only of the
engine**. The CLI client does read `KIRO_ENABLED_FEATURES`, and its shipped
experiment catalog contains a `workflows` entry whose own description says
`enable locally through KIRO_ENABLED_FEATURES`. **That flag has no consumer.**
The only literal `isEnabled` calls in the client are for `remote_sandbox` and
`c2s`; the only feature-to-setting mapping table is
`[["memory","memoryEnable"]]`; the only feature-gated slash command is
`feature:"remote_sandbox"`. So setting `KIRO_ENABLED_FEATURES` to include
`workflows` is inert at 2.15.1 — the vendor's own instruction does not work.
Recording this as an absence-with-a-decoy is more useful than either "no env var
exists" (which a reader would disprove in one grep and then distrust the rest)
or "there is an env var" (which would send them down a dead end).

**Why it matters:** it closes the cheapest hypothetical enable path and explains
why the persisted-metadata route (R-workflow-2) is the only one. It also
predicts where the supported path will appear: the catalog entry exists, so the
intended future is a client feature flag, and the day it gains a consumer the
persisted-metadata hack becomes unnecessary.

**Semantic anchor:** on the engine side, look for any environment read whose
name concerns workflows, and for the engine's feature predicate — a helper
taking a string key, whose call sites are all literals. Neither yields a
workflow key. On the client side, a small class lazily parses one environment
variable as a JSON array of strings into a `Set` and exposes a membership
predicate; a sibling getter reads a separate "internal user" variable. A JSON
catalog of experiments sits elsewhere in the binary, each entry carrying a
description, a treatment percentage, and optional segment/channel; the workflow
entry is at 0% with an "internal" segment and a "nightly" channel and points the
reader at the environment variable. What the catalog does **not** have is a
reader for that particular key: the predicate is only ever called with two other
literals, the one table that translates a feature into a wire setting has a
single row for memory, and the slash-command list filters on an optional
per-command `feature` field that exactly one command sets.

**Verified against:** KAS
`2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc`
(kiro-cli 2.15.1), 2026-07-29.

**Drift:** 2.15.2 changed — see `../drift-ledger.md`

**Command** (the engine half):

```bash
env_names() { { grep -boE 'process\.env\.[A-Za-z_][A-Za-z_0-9]*' "$bundle" || true; } | sed 's/^[0-9]*://' | sort -u; }
echo "process.env occurrences:        $(occ 'process.env')"
echo "distinct process.env.<NAME>:    $(env_names | wc -l)"
echo "...matching work|flow (i):      $({ env_names | grep -icE 'work|flow' || true; })"
echo "KIRO-related:"
env_names | grep -E 'KIRO'
echo "bracket-form distinct:          $({ grep -boE 'process\.env\[[^]]{0,40}\]' "$bundle" || true; } | sed 's/^[0-9]*://' | sort -u | wc -l)"
echo "...matching work|flow (i):      $({ { grep -boE 'process\.env\[[^]]{0,40}\]' "$bundle" || true; } | sed 's/^[0-9]*://' | sort -u | grep -icE 'work|flow' || true; })"
{ grep -boE 'isFeatureEnabled\("[a-zA-Z_0-9]+"\)' "$bundle" || true; } | sed 's/^[0-9]*://' | sort | uniq -c
grep -boE 'KIRO_LOAD_ALL_REMOTE_TOOLS_ENV = "[^"]*"' "$bundle"
```

**Output at capture:**

```
process.env occurrences:        180
distinct process.env.<NAME>:    63
...matching work|flow (i):      0
KIRO-related:
process.env.ASBX_KIRO_MANDATORY_MCPS
process.env.KIRO_API_KEY
process.env.KIRO_CHAT_LOG_FILE
process.env.KIRO_CONTENT_COLLECTION_ENABLED
process.env.KIRO_CUSTOM_USER_AGENT
process.env.KIRO_DISABLE_RECAP
process.env.KIRO_DUMP_REQUESTS
process.env.KIRO_DUMP_REQUESTS_DIR
process.env.KIRO_LOG_LEVEL
process.env.KIRO_REMOTE_SESSIONS_ENDPOINT
process.env.KIRO_SUPERVISOR_DEBUG
process.env.KIRO_TOOL_SEARCH_THRESHOLD
bracket-form distinct:          52
...matching work|flow (i):      0
```

```
      5 isFeatureEnabled("c2s")
      1 isFeatureEnabled("infraSafetyEnforce")
      1 isFeatureEnabled("infraSafetyMonitor")
      1 isFeatureEnabled("largeToolOutputHandler")
      1 isFeatureEnabled("memoryEnable")
      1 isFeatureEnabled("mergeVibeSpec")
      1 isFeatureEnabled("sessionRecap")
      1 isFeatureEnabled("steeringReminders")
      1 isFeatureEnabled("subagentOrchestration")
      2 isFeatureEnabled("verifyFirstWorkflow")
```

```
19991538:KIRO_LOAD_ALL_REMOTE_TOOLS_ENV = "KIRO_LOAD_ALL_REMOTE_TOOLS"
```

**Denominators:** 63 dot-form + 52 bracket-form environment references, 0
matching work/flow; 12 KIRO-related dot-form names plus one bracket-form
constant (`KIRO_LOAD_ALL_REMOTE_TOOLS`) makes **13 KIRO env vars in the
engine**, none workflow-related. 10 distinct feature keys, 15 call sites;
`verifyFirstWorkflow` is the only one containing the substring and it belongs to
the **spec** surface, not this one.

**Command** (the client half — the decoy):

```bash
cnames() { { grep -aboE 'process\.env\.[A-Za-z_][A-Za-z_0-9]*' "$rustchat" || true; } | sed 's/^[0-9]*://' | sort -u; }
echo "distinct process.env.<NAME> in client JS: $(cnames | wc -l)"
echo "...matching work|flow (i):"; cnames | grep -iE 'work|flow'
head -c $((396159700)) "$rustchat" | tail -c 470 | tr -c '[:print:]\n' '.'
head -c $((398654620)) "$rustchat" | tail -c 316 | tr -c '[:print:]\n' '.'
{ grep -aboE 'isEnabled\("[a-z_0-9]+"\)' "$rustchat" || true; } | sed 's/^[0-9]*://' | sort | uniq -c
{ grep -aboE 'feature:"[a-z_0-9]+"' "$rustchat" || true; }
{ grep -aboE 'W0n=\[\[[^]]*\]\]' "$rustchat" || true; }
```

**Output at capture:**

```
distinct process.env.<NAME> in client JS: 128
...matching work|flow (i):
process.env.CMUX_WORKSPACE_ID
process.env.JEST_WORKER_ID
```

```
bar:{named:"gray"}}}},textStyles:{label:{color:"primary"},selectedLabel:{color:"accent",weight:"bold"}}};var XB=Ee(Me(),1);class Cae{enabled=null;get enabledSet(){if(this.enabled===null)this.enabled=vXe(process.env.KIRO_ENABLED_FEATURES);return this.enabled}isEnabled(e){return this.enabledSet.has(e)}get isInternalUser(){return process.env.KIRO_INTERNAL==="1"}_resetForTests(){this.enabled=null}}function vXe(e){if(!e)return new Set;try{let n=JSON.parse(e);if(Array.isA<<<
```

```
a treatment_percent.",
    "treatment_percent": 100,
    "segment": "internal",
    "channel": "nightly"
  },
  "workflows": {
    "description": "KAS dynamic workflows and TUI workflow management. Dark-shipped at 0% until release certification is complete; enable locally through KIRO_ENABLED_FEATURES.",
    "treat<<<
```

```
      2 isEnabled("c2s")
      3 isEnabled("remote_sandbox")
```

```
396163096:feature:"remote_sandbox"
```

```
396741232:W0n=[["memory","memoryEnable"]]
```

The two client env names that match the filter — `CMUX_WORKSPACE_ID` and
`JEST_WORKER_ID` — are a terminal-multiplexer id and a Jest worker id. Neither
concerns workflows; the filter is deliberately over-broad so its hits can be
dismissed by inspection rather than by a narrower regex nobody can audit.

**Positive controls:** every absence above sits beside a non-zero control read
from the same file by the same method.

```bash
for s in process.env isFeatureEnabled FeatureKey featureFlags run_workflow \
         send_message workflowsEnabled resolveWorkflows \
         KIRO_ENABLED_FEATURES KIRO_WORKFLOWS KIRO_ENABLE_WORKFLOWS \
         'isFeatureEnabled("workflows")' 'process.env.KIRO_WORKFLOWS_ENABLED'; do
  printf '%-34s %s\n' "$s" "$(occ "$s")"
done
```

```
process.env                        180
isFeatureEnabled                   39
FeatureKey                         11
featureFlags                       23
run_workflow                       26
send_message                       84
workflowsEnabled                   14
resolveWorkflows                   4
KIRO_ENABLED_FEATURES              0
KIRO_WORKFLOWS                     0
KIRO_ENABLE_WORKFLOWS              0
isFeatureEnabled("workflows")      0
process.env.KIRO_WORKFLOWS_ENABLED 0
```

The first eight rows are the **controls**: the env mechanism, the feature-flag
mechanism, and the workflow surface itself are all demonstrably present in the
bundle at capture. The last five are the **absences**: the env names and the
feature key a workflow override would plausibly have used, none of which exists
— including `KIRO_ENABLED_FEATURES`, which the client reads and **the engine
does not**. A re-run reporting the absence rows still 0 and the control rows
near these values confirms the negative. A re-run where the control rows
collapse toward 0 has lost its grip on the bundle; the feature has not been
removed.

**Notes:** the client's feature set is parsed from JSON, so the shape is
`KIRO_ENABLED_FEATURES='["workflows"]'`, not a comma-joined list — worth knowing
before concluding "I set it and nothing happened" for the wrong reason. This
record is a **static** read: it shows no code path from an environment variable
to the workflow gate, and cannot show that some future build's launcher does not
translate one. The single most valuable thing a re-run can check is whether
`isEnabled("workflows")` has appeared, or whether a `["workflows", ...]` row has
joined the feature-to-setting table — either would mean the decoy became real,
and would supersede R-workflow-2's persisted-metadata path with a supported one.
This record also goes stale if the engine gains any workflow-named env read, or
if `isFeatureEnabled` acquires a `workflows` key.
