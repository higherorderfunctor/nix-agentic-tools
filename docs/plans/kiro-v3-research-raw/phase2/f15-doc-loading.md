# F15 — How referenced documents load (steering, skills, AGENTS.md, resources)

> Verified against: KAS 2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc (kiro-cli 2.15.1 installed; companion ACP argv doc measured 2.15.2). Date: 2026-07-30.

## 1. The question

When a steering file, skill, or agent profile references another document —
or when a document is merely present in a scanned directory — does its content
enter model context automatically, or does it cost the model an explicit tool
call? Settled means: every inclusion mode enumerated with its exact matching
semantics and consumer; every auto-load channel named with its injection point;
every activation lever mapped to who can pull it; every byte/token budget found
or bounded-negative with positive controls; and the `#[[file:...]]` reference
syntax traced to its consumer (or proven unconsumed) rather than trusted from
prose.

## 2. What is already known

- Corpus `evidence/machine-state.md` (event-kind census): `steering_inclusion`
  is a persisted messages.jsonl event kind — 158 root rows + 615 sub-execution
  rows in the corpus. This is the discriminating observable used below.
- Corpus `records/workflow-surface.md` (~L717-729): the session steering list
  appends the bundled `workflows_default` steering doc when workflowsEnabled,
  or `WORKFLOW_STEP_COMPLETION_PROTOCOL` when the session runs a workflow.
- Corpus `records/hooks-dispatch-gate.md` (~L850-860): dispatched
  sub-executions inherit `steering: state2.execution.steering` (the
  definition-level string list) from the parent; `previousMessages: void 0`
  makes every sub-execution first-turn.
- Corpus `records/limits-and-engine.md` (~L1180-1230): the KAS settings key
  space; `_steeringReminders` is an experimental (underscore) key,
  `largeToolOutputHandler` a stable one; the CLI forwards only a fixed array of
  keys at initialize.
- Memory (2026-07-21, engine 2.13.0, empirical): v3 drops symlinked steering
  FILES; v2 follows them. Re-confirmed here from 2.15.1 code (section 3.2).
- Vendor `private/kiro-v3-docs.md` L63, 262-264, 460, 711-715: claims steering
  has "front matter metadata", skills are "unchanged", agent resources accept
  `skill://backend-patterns`, and a `skill` permission capability exists.
  Verified/corrected below.

## 3. The interface, fully enumerated

### 3.0 Two distinct channels

Steering-ish content reaches the model over two channels that never mix:

- **Channel A — definition string list** (`steering: string[]` on the
  execution definition): rendered into msg0's system-prompt TEXT as a
  `<steering-files>` block (`composeSystemPrompt`,
  `src/utils/prompt-building/compose-system-prompt.ts`, byte 14245875).
  Members: `session.globalSteering` (populated ONLY by a `get_steering_files`
  MCP prefetch when a remote MCP client exists and no cloud-config root —
  empty in a plain local run; byte 20449462), static per-mode steering,
  `workflows_default` / `WORKFLOW_STEP_COMPLETION_PROTOCOL` (corpus), and — for
  custom agents — the CONTENT of every `file://` profile resource, re-read from
  disk EVERY TURN (`resolveAgentResourcesForSession`, byte 20596149).
- **Channel B — steering document entries**: filesystem docs attached as typed
  `{type:"document", document:{type:"steering",...}}` entries on context
  messages. Injection points: msg0 (`attachSteeringDocuments`, byte 14150844 —
  all always-included docs), the turn-start `populateMatchedSteering` graph
  node (byte 13834511), and the mid-turn `PostToolSteering` node (byte
  14080000 region). Channel B is what emits `actionType: "steering"` actions →
  `steering_inclusion` rows in messages.jsonl.

### 3.1 Steering frontmatter schema (`src/types/steering.ts`, byte 14723755)

```
SteeringContextFrontMatterSchema = z.object({
  inclusion: z.enum(["always", "fileMatch", "manual", "auto"]).optional().nullable(),
  fileMatchPattern: z.string().or(z.string().array()).optional().nullable(),
  name: z.string().optional(),
  description: z.string().optional()
})
```

Complete consumer census of the enum (denominator: every
`inclusion === "<value>"` comparison in the 2.15.1 bundle): `always` 4 sites,
`fileMatch` 1 (+3 negated), `manual` 2, `auto` 1 (+2 negated). All eight are
accounted for in the mode table below — there is no hidden fifth consumer.

| mode | who loads it | when | cost to model |
| --- | --- | --- | --- |
| absent / null | same as `always` | msg0 + per-turn top-up | free (auto-injected whole) |
| `always` | `getAlwaysIncludedDocuments` (byte 19328014) | msg0 + per-turn top-up | free |
| `fileMatch` | `getMatchedDocuments` via minimatch | turn-start file scan + mid-turn post-tool | free once a matching file is touched |
| `manual` | engine NEVER auto-loads; exposed as a slash command only | user/client action | free to model, user-driven |
| `auto` | ProgressiveContextSource → `disclose_context` tool; ALSO a slash command | model elects | one tool call (approval-gated) |

**Trap — invalid frontmatter degrades to `always`.** `loadSteeringDocument`
(byte 19331400 region) wraps `parseFrontMatter` in try/catch; on ANY failure
(YAML error or Zod enum violation) it sets `parsedConfig = undefined` and
`parsedContent = content` (raw, frontmatter text included). Undefined config
means always-included. js-yaml CORE (corpus: yes/no are NOT booleans) makes
`inclusion: no` the string `"no"` → enum violation → the doc silently becomes
an always-loaded doc with its broken frontmatter injected as content. The
progressive (auto) parser is stricter: `FrontMatterLoadError` → warn + skip.

**`fileMatch` matching semantics** (`matchesFileMatchPattern`, byte 19325713):
`minimatch(relativePath, pattern, { dot: true, nocase: <fs-case-insensitive> })`
where relativePath is the file's path RELATIVE to its containing workspace
folder (backslashes normalized to `/`). `dot: true` means dotfiles match `*`.
The doc must have BOTH `inclusion: "fileMatch"` AND a pattern; a pattern on an
`auto` doc is dead config. Non-global docs only match files inside their own
workspace folder; global (`~/.kiro/steering/`) fileMatch docs match against
any workspace's files.

**What counts as a "file in context"** (fileMatch triggers):

1. Turn-start (`populateMatchedSteering` → `context.getWorkspaceFiles()`, byte
   13781527): `document`-entries of type `file` (client attachments) plus the
   args of prior `read_file` / `read_files` toolUse entries. NOT grep, NOT
   fs_write, NOT execute_bash.
2. Mid-turn (`PostToolSteering`): every SyncTool reports `fileAccesses`; both
   `read` and `write` kinds call `addSteeringTriggerPath` (byte 17112465);
   paths drain after each tool execution and matching docs inject immediately,
   appended to the last tool message (byte 14080000 region). So writes DO
   trigger fileMatch steering, just via the mid-turn path.

Both paths inject net-new docs only (dedup by doc id against
`context.getWorkspaceSteering()`), each injection emitting an
`actionType: "steering"` action whose `input.documents` carry full content →
persisted as `steering_inclusion`. On the FIRST session turn a synthetic
`steering-msg0-<executionId>` action announces the msg0 docs by id only
("content is already on msg0" comment) — reload does not re-inject.

### 3.2 Discovery, scan, trust, symlinks

`NodeSteeringDocumentSource` (byte 19325713 region) scans, per
`listSteeringFilePaths`:

1. `AGENTS.md` at each workspace folder ROOT (exact name, no recursion, no
   frontmatter parsing — hardcoded `config: { inclusion: "always" }`, source
   `"agents-md"`). An AGENTS.md placed INSIDE a steering directory is instead
   parsed as a normal steering doc (`isInSteeringDirectory`, byte 19336400
   region). `CLAUDE.md`: 0 hits in the bundle (positive controls: `AGENTS.md`
   4 hits, `"agents-md"` 1 hit) — not read.
2. `<workspace>/.kiro/steering/` — recursive, `.md` suffix.
3. `~/.kiro/steering/` (join(homeDir, ".kiro", "steering")) — recursive —
   plus a cloud-replica steering dir prepended when in-sandbox. Files here get
   `scope: "global"` and a displayName that is the path relative to the global
   dir minus `.md` (subdirectories become part of the name); workspace docs
   get bare-basename displayNames.

**Symlink asymmetry (two different `findMarkdownFilesRecursively`):** the
steering source's version (byte 19336400 region) checks `entry.isFile()` /
`entry.isDirectory()` on raw Dirents — a symlink satisfies neither, so
symlinked files AND symlinked subdirectories are silently skipped (confirms the
2.13.0 empirical memory note at 2.15.1). The progressive source's version
(byte 19384515 region) explicitly stats symlinks, follows them, and carries a
realpath cycle guard — so `inclusion: auto` steering and skills DO tolerate
symlinks, while `always`/`fileMatch`/`manual` steering does not. Skill
directory entries additionally accept `entry.isSymbolicLink()` directly
(`scanSkillsDirectory`).

**Trust gate:** with `workspaceTrusted` false, both the steering source
(`listContextDocuments`) and the progressive manager (`runScanAndCache`, byte
19378577) filter to `scope === "global"` only. Workspace steering, workspace
AGENTS.md, and workspace skills all vanish; home/global ones survive. Loading
is not otherwise gated.

**Watchers:** chokidar on `.kiro/steering` + `AGENTS.md` (steering manager)
and `.kiro/skills` + `.kiro/steering` (progressive manager, 300 ms debounce)
rescan on change; the always-included cache (`CachingSteeringDocumentSource`,
one-shot promise cache, byte 19351867 region) is invalidated and the client is
re-notified (`_kiro/progressive_context/items_changed`).

**Merge and dedup:** per read,
`unique([...clientAlways, ...clientMatched, ...always, ...matched])` — dedup
by id, LAST wins, so filesystem docs beat client-provided docs on id
collision (byte 19359906). Builtin docs append after filesystem docs
(`BuiltinSteeringDocumentSource`). Progressive items dedup by displayName,
last wins, scan order cloud → home-global → workspaces (workspace shadows
global); registered items (agent `skill://` resources, client helpDocs)
override scanned items of the same displayName.

**Builtin steering docs** (byte 19348007): exactly three, all
`inclusion: "manual"` — `architecture-selection`, `quick-spec`, `bug-fix`.
They therefore surface ONLY as slash commands (feeds F2).

### 3.3 Skills and progressive disclosure (`disclose_context`)

`SkillFrontMatterSchema` (byte 14723938):
`{ name?, description?, license?, compatibility?, metadata? } .passthrough()`.

Discovery: `<root>/.kiro/skills/<dir>/SKILL.md` for root ∈ {cloud replica,
home, each workspace}. A SKILL.md missing frontmatter, or missing `name` or
`description`, is warn-logged and SKIPPED — it is not addressable at all.
`inclusion: auto` steering files join the same item pool but require
`description` (their displayName = frontmatter `name` || basename).

The ONLY consumer is the `disclose_context` tool (id `disclose_context`, class
`_DiscloseContext`, byte 18181200 region), registered unconditionally per ACP
session (byte 19309862) — even with zero items (description then says "None").

- Its DESCRIPTION dynamically lists every visible item:
  `name: "<x>" - <description>` under `**Skills:**` and
  `**Steering Files:**` headings, with imperative text ("BLOCKING
  REQUIREMENT: invoke ... BEFORE generating any other response"). This is the
  progressive-disclosure index — Claude-skill-like, but ONE level only.
- Input schema: `{ name: string }` (exact displayName; skills also match
  `config.name`).
- The call goes through `acpToolApproval` (so the client/permission engine can
  gate it — vendor capability `skill`); policy-denied skills
  (`isResourceDenied("skill", name)`) are filtered from the description.
- Content: file re-read from disk, frontmatter STRIPPED, returned whole as the
  tool result. Session-visibility check: non-global items must belong to the
  session's workspace.
- Unknown name → error message enumerating available names.
- Success emits `actionType: "disclose_context"` with
  `output.contentLength` + item meta — persisted, and surfaced to the client
  with `Loaded skill: <name>` titling.

**No bundle mechanism.** A skill is exactly one SKILL.md; other files in the
skill directory are never enumerated, attached, or resolved. If the SKILL.md
body says "read references/foo.md", that costs the model an fs_read tool call
with a path the model must construct itself. No relative-link resolution
exists in any loaded content (searches: `resolveRelative` near skill code,
`referenced file`, `readReference`, `SKILL_DIR`, `skillRoot` — no loader-side
hits; positive controls: `SKILL_MD_FILENAME` 3 hits, `scanSkillsDirectory`
present).

**Client-provided help docs:** initialize `_meta.kiro.helpDocs`
(`{name, description, content}[]`, byte 20293451) register as builtin skills
(`builtin:<name>` URIs, content served from memory, not disk).

**Agent-profile `resources`:** entries are strings or knowledge-base objects
(`classifyUri`, byte 17214915): `file://<path>` → files, `skill://<path>` →
skills, any other scheme warn-dropped. Path resolution
(`resolveResourcePaths`, byte 19979575): absolute, `~`-prefixed (home), else
workspace-relative; globs expand (`nodir`). `skill://` targets must be a FILE
in SKILL.md format with name+description frontmatter — the vendor example
`skill://backend-patterns` is a PATH lookup (`<workspace>/backend-patterns`),
NOT a name lookup into `.kiro/skills/`. Resolved skills are REGISTERED into
the progressive pool (still lazy — model must disclose); `file://` contents
are EAGERLY injected each turn via Channel A (and reported by
`_kiro/session/context show` breakdown).

### 3.4 Manual mode and user-attached context

Engine-side, `manual` docs are inert as context: excluded from
always-injection, from fileMatch matching, and from the progressive pool.
Their only surface is `createSteeringCommandSource` (byte 19423560): every
`manual` OR `auto` doc becomes an advertised slash command
(`available_commands_update`, type `steering`, with
`contextQuery: "<scope>:<fsPath>"`). Execution is CLIENT-mediated — the engine
ships no handler; the client is expected to resolve the fsPath into attached
context. Naming trap: the slash-command name uses the loader displayName
(basename / global-relative path); the disclose_context name for the SAME
`auto` file uses frontmatter `name` when present — one file, two different
activation names.

The generic user-attach path is `_kiro/session/context` (advertised extension
method): `add` stores PATHS, not snapshots; every turn re-reads each file and
injects `## <path>\n<content>` blocks (`resolveContextFilesForInjection`, byte
20594278) as `liveContextBlocks`; unreadable/deleted entries are skipped with
a log, reported `matched: false` in `show`. No size cap.

### 3.5 `#[[file:...]]` — parsed, but there is no `file` provider

- The literal `#[[file:` appears exactly 3 times in the bundle — ALL inside
  system-prompt PROSE (kiro-web/kiro-ide `getSteering`/spec blocks, bytes
  5045417, 5050371, 5051943) telling the model that steering and spec files
  support file references.
- A real parser exists: `CONTEXT_REF_REGEX = /#\[\[([^\]]+)\]\]/g`
  (`kiro-context-providers/dist/utils/parse-context-references.js`, byte
  16916364) parsing `#[[providerId:query]]`.
- Its ONE consumer is `processPromptWithContext` (byte 17176373), applied ONLY
  to custom-agent/sub-agent SYSTEM PROMPTS (single call site, byte 18028393).
  Steering content, skill content, AGENTS.md, and context files are NEVER run
  through it.
- The registry holds exactly TWO providers at 2.15.1 (registration site byte
  20484942): `fileTree` and `currentlyOpenFiles`. There is NO `file` provider
  (`id = "file";` → 0 hits; positive controls: `id = "fileTree";` and
  `id = "currentlyOpenFiles";` found).

Net: `#[[file:x]]` in a steering file arrives at the model as literal text; in
a custom-agent prompt it logs `Provider 'file' not found` and stays literal.
The engine's own system prompt over-promises an IDE-only feature (corpus C-11
state: documented-but-unconsumed). What DOES work in an agent prompt:
`#[[fileTree]]` and `#[[currentlyOpenFiles]]`.

### 3.6 Budgets, caps, and what happens past them

- **No per-document size cap on any load path.** Steering docs, AGENTS.md,
  SKILL.md disclosure, context files, and `file://` resources are read whole
  with `fs.readFile` and injected/returned whole. Bounded negative —
  searches: `truncateSteering`-style identifiers (0), `MAX_STEERING` (0),
  `MAX_CONTEXT_FILE`/`maxContextFiles` (0); positive controls in the same
  bundle: knowledge indexing has `MAX_FILE_SIZE`, large-output has
  `BASE_THRESHOLD`, reminders have `STEERING_REMINDER_BUDGET`.
- **disclose_context is explicitly exempt from the large-output handler.**
  `LARGE_OUTPUT_CONFIG` (byte 12845489): threshold 30 000 chars, but
  `HANDLED_TOOLS = ["execute_bash", "get_process_output", "web_fetch",
  "remote_web_search"]` + `mcp_` prefix only, with a source comment naming
  "context-injection reads like steering/skill disclosure — passes through
  untouched". A 1 MB skill body lands in context intact.
- **The only steering budget is on the REMINDER path.**
  `STEERING_REFRESH_INTERVAL = 10`, `STEERING_REMINDER_BUDGET = 10000`
  (CHARS, not tokens — log text says "char budget"; byte 13838472). When the
  experimental `steeringReminders` feature is on, every 10 assistant messages
  the always-included docs are re-sent inside `<steering-reminder>` tags;
  `selectDocumentsWithinBudget` greedily takes docs IN LIST ORDER until 10 000
  chars and silently drops the rest (info log only, no model-visible marker).
  A second guard skips the whole refresh if estimated context
  (`chars/4`) + reminder would exceed 90% of `maxInputTokens`. Engine default
  for the flag is OFF: `isSettingEnabled` returns false for absent keys and
  the stub provider returns false (bytes 867793, 5041063); it turns on only if
  the client's initialize `_meta.kiro.settings` carries it.
- Past-cap behavior elsewhere is therefore: no truncation, no refusal, no
  message — oversized always-steering simply consumes context until generic
  compaction/eviction acts (out of F15 scope; corpus C-9 for the sub-execution
  compaction hazard).

## 4. Activation drivers

| lever | user-typed | skill-invoked | agent-sys-prompt | model-elected | hook-driven | workflow-step | external-ACP-client |
| --- | --- | --- | --- | --- | --- | --- | --- |
| always/absent steering + AGENTS.md | — (presence in dir is enough) | — | — | — | — | — | client steering docs at session/new |
| fileMatch steering | attach a matching file | — | — | YES — any read_file/read_files or tool file write | — | steps whose tools touch files | attach file docs |
| manual steering | YES — slash command / attach | — | — | NO | — | — | YES — resolve contextQuery, `session/context add` |
| auto steering + skills (disclose_context) | ask for the task it describes | self-referential | agent text can order a disclose | YES — primary path | — | steps can elect it | approval gate sits client-side |
| `file://` agent resources | — | — | YES — profile author | — | — | — | client-provided agent profiles |
| `skill://` agent resources | — | — | YES — profile author (registers, still model-elected to open) | YES (to open) | — | — | same |
| `_kiro/session/context` files | YES (TUI /context) | — | — | NO | — | — | YES — extension method |
| helpDocs builtin skills | — | — | — | YES (to open) | — | — | YES — initialize `_meta.kiro.helpDocs` |
| `#[[provider]]` in agent prompt | — | — | YES — only surface | — | — | — | profiles it supplies |
| steeringReminders re-injection | — | — | — | — | — | — | YES — initialize settings key |

Hook-driven: no hook output path feeds any of these loaders (hooks inject raw
stdout/stderr text, corpus hooks-io-contract); a hook can of course WRITE a
steering file, which the watcher picks up within ~300 ms — indirect only.

## 5. Fixture design (probe pair + discriminating observables)

My item does not authorize launching the engine, so this is a SPEC. Everything
below needs NO model call except probe P6.

**Workspace fixture** `fixtures/kiro-doc-loading/` (workspace root `ws/`):

```
ws/AGENTS.md                                  # marker AAA-AGENTSMD
ws/.kiro/steering/s-default.md                # no frontmatter, marker AAA-DEFAULT
ws/.kiro/steering/s-always.md                 # inclusion: always, marker AAA-ALWAYS
ws/.kiro/steering/s-filematch.md              # inclusion: fileMatch, fileMatchPattern: "src/**/*.ts", marker AAA-FM
ws/.kiro/steering/s-manual.md                 # inclusion: manual, description: DMANUAL
ws/.kiro/steering/s-auto.md                   # inclusion: auto, name: auto-alias, description: DAUTO, marker AAA-AUTO
ws/.kiro/steering/s-broken.md                 # inclusion: sometimes  (enum-invalid), marker AAA-BROKEN
ws/.kiro/steering/s-link.md -> ../real.md     # symlinked file, marker AAA-LINK
ws/.kiro/steering/ref.md                      # inclusion: always, body contains #[[file:target.md]] and target.md exists
ws/.kiro/skills/good/SKILL.md                 # name: good-skill, description: DGOOD, body marker AAA-SKILL + "read EXTRA.md"
ws/.kiro/skills/good/EXTRA.md                 # marker AAA-EXTRA (bundle-followup probe)
ws/.kiro/skills/nodesc/SKILL.md               # name only, no description
ws/.kiro/skills/huge/SKILL.md                 # valid, body >40 000 chars (cap probe)
ws/src/x.ts                                   # fileMatch trigger target
```

**Session script** (ACP stdio, isolated HOME per the settled isolation lever;
`initialize` → `session/new` with workspacePaths=[ws]):

- P1 (no model): capture `available_commands_update`. PASS iff it contains
  steering commands `s-manual` AND `s-auto` (loader displayName, NOT
  `auto-alias`) and NONE for s-always/s-default/s-broken/s-link; plus the
  three builtins architecture-selection/quick-spec/bug-fix.
- P2 (no model): capture `_kiro/progressive_context/items_changed`. PASS iff
  items = {good-skill, auto-alias} — `nodesc` absent (description required),
  `huge` present.
- P3 (no model): touch `ws/.kiro/steering/s-new.md` (inclusion: auto,
  description) mid-session; expect a fresh items_changed within ~1 s
  (300 ms debounce) listing it.
- P4 (no model): repeat session/new with an UNTRUSTED workspace variant; P1/P2
  lists must shrink to global+builtin items only.
- P5 (no model): `initialize` with `_meta.kiro.helpDocs:[{name:"helpx",...}]`;
  items_changed must include `helpx`.
- P6 (model turn — SPEC ONLY, one cheap prompt "reply ok"): afterwards parse
  `~/.kiro/sessions/<hash>/sess_*/messages.jsonl`. PASS iff (a) a
  `steering_inclusion` row (or the msg0 card) lists ids for s-default,
  s-always, s-broken (broken proves the always-degrade trap), AGENTS.md, and
  ref.md but NOT s-filematch/s-manual/s-auto/s-link; (b) the persisted msg0
  document for ref.md contains the literal `#[[file:target.md]]` (no
  expansion); (c) a second turn "read src/x.ts then reply ok" adds a
  `steering_inclusion` row for s-filematch only; (d) a third turn "activate
  good-skill" shows a `disclose_context` tool_call whose result carries
  AAA-SKILL in full and no `[LARGE OUTPUT]` wrapper, and activating `huge`
  returns its full body (cap probe); (e) `auto-alias` (not `s-auto`) is the
  accepted disclose name, `s-auto` errors with the available-names message.

Discriminators are all string-exact (markers, event kinds, command names), so
each probe fails loud. P1-P5 are safe to automate now; P6 costs 3 model turns
and is deferred to the F8-style observability fixture run.

## 6. Cross-interactions

- **F2 (slash commands):** manual/auto steering docs and the three builtin
  manual docs are slash-command SOURCES; enumeration there must include the
  steering-sourced ones or it undercounts.
- **F8 (model/effort):** none — no loader consults model config except the
  reminder context-window guard (`maxInputTokens`).
- **Workflows:** `workflows_default` / step-protocol steering rides Channel A
  (string list), so it never appears as a `steering_inclusion` document row —
  do not use that event to test workflow steering.
- **Sub-executions:** inherit Channel A strings from the parent; Channel B
  runs independently inside the sub-graph (615 corpus sub rows), so a worker
  in the same workspace re-pays the full always-steering context cost per
  sub-execution — compounding the C-9 compaction hazard for big steering sets.
- **Hooks:** hook loading is flat/symlink-skipping (corpus); steering scanning
  is recursive with a DIFFERENT symlink rule per inclusion mode (3.2) — three
  loaders, three symlink behaviors; do not generalize across them.
- **Permissions:** `disclose_context` is the only lever with a permission
  capability (`skill`); always/fileMatch injection bypasses the permission
  engine entirely — a deny-all policy still gets steering injected.
- **Trust:** untrusted workspace silently drops workspace steering/skills but
  keeps global ones — a fixture asserting "no steering" under distrust is
  wrong if `~/.kiro/steering/` is not empty (isolate HOME).
- **This repo's content strategy:** path-scoped fragments map to
  `inclusion: fileMatch` (auto-injected, zero model cost, but ONLY fire on
  read_file/read_files/write — not on grep/bash access); reference docs map
  better to `inclusion: auto` + description (model-elected, approval-gated,
  no size limit); nothing supports multi-file bundles — anything beyond one
  file must be an explicit fs_read instruction inside the disclosed body.
