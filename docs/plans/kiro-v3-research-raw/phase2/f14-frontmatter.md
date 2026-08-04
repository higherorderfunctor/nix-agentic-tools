# F14 — Frontmatter control surfaces, exhaustively

> Verified against: KAS 2.15.1-e20633b4f836d12b79adc6440da750d6afc3a0fdd25ec4c68056ab5b6fac12fc (kiro-cli 2.15.1 installed; companion ACP argv doc measured 2.15.2). Date: 2026-07-30.

## 1. The question

For every authorable file type the v3 KAS engine reads — agent profiles (.md
and .json), skills, steering documents, hooks, specs, permissions files —
enumerate every frontmatter/config key from the actual Zod/js-yaml parse sites,
with type, default, effect, file-location resolution, and override semantics.
"Settled" = every key traced to a schema declaration AND its consumer, with
vendor-doc discrepancies called out.

## 2. What is already known (carried in, not re-derived)

- Frontmatter is js-yaml CORE schema — `yes`/`no` are strings, not booleans
  (corpus, settled facts).
- A `.json` agent profile carrying `allowedTools`/`toolsSettings` and no
  `permissions` is silently skipped (corpus; exact mechanism confirmed below).
- Agent loader follows symlinks and recurses; hook loader silently skips
  symlinked files and scans flat (corpus; confirmed at the cited parse sites).
- Home agent profiles load unconditionally; workspace profiles are trust-gated.
  Hook LOADING is not trust-gated, execution is (corpus records
  hooks-dispatch-gate R-hooks-*).
- Hook stdin payload per trigger: corpus hooks-io-contract R-hookio-1.
- Builtin mode ids (vibe|spec|quick-spec|bug-fix|plan|autonomous) load then get
  filtered (corpus).
- Steering symlinked FILES dropped by the main steering loader (memory record,
  2.13.0) — still true at 2.15.1 for `NodeSteeringDocumentSource`, but NOT for
  the progressive-context scanner (new finding, section 3.4).

**Denominator for "exhaustive":** the bundle has exactly ONE frontmatter parser
(`parseFrontMatter`, src/utils/front-matter/parse-front-matter.ts, def at byte
6160955) and exactly 5 call sites (grep `parseFrontMatter\(\{`): agent .md
(17221814, `CustomAgentFileFrontMatterSchema`), steering (19332580 main source +
19387362 progressive, `SteeringContextFrontMatterSchema`), SKILL.md (19385598
progressive scan + 19981271 agent `skill://` resolver, `SkillFrontMatterSchema`).
Hooks and permissions are whole-file JSON/YAML (no frontmatter); specs are
structural markdown (no frontmatter). That is the complete surface.

### The shared parser (applies to all frontmatter surfaces)

- `loadAll(raw, { schema: CORE_SCHEMA, maxAliases: 20 })`; >1 YAML document in
  the block throws. Delimiter language tag supports `yaml`/`yml`/empty and
  `json` (`JSON.parse`); anything else throws.
- Empty frontmatter block → `frontMatter: undefined` (not `{}`).
- Zod `safeParse` failure → throws `FrontMatterLoadError`. Each surface handles
  the throw differently (the failure-mode table in section 6 is the single most
  fixture-worthy output of this item).

## 3. The interface, per surface

### 3.1 Agent profiles — `.md` frontmatter (`CustomAgentFileFrontMatterSchema`, byte 17207977)

| Key             | Type (Zod)                                          | Default     | Effect |
| --------------- | --------------------------------------------------- | ----------- | ------ |
| `name`          | `string.min(1)` optional                            | filename id | Overrides filename-derived agent id |
| `description`   | `string` optional                                   | `""`        | Shown in slash-command list / delegation |
| `tools`         | `string \| string[]` optional                       | `undefined` = NO tools | Comma-split if string; `"*"` = all; empty entries dropped; empty result → undefined |
| `excludedTools` | `string[]` optional                                 | —           | Applied after `tools` matching |
| `model`         | `string` optional                                   | —           | Model override |
| `effortLevel`   | `string` optional (NOT an enum — any string parses) | —           | Effort for reasoning models |
| `includeMcpJson`| `boolean` default(false)                            | `false`     | Auto-include all MCP tools |
| `includePowers` | `boolean` default(false)                            | `false`     | Auto-include kiroPowers tool |
| `mcpServers`    | `McpServerWireRecordSchema` (preprocess: non-object → undefined; record of unknown) | — | Per-agent MCP servers; entries classified later so ONE malformed entry fails that server, not the profile |
| `resources`     | `AgentResourcesSchema` — array of unknown; invalid entries LOGGED+DROPPED per-entry | — | `file://`, `skill://`, knowledge-base objects |
| `permissions`   | `PermissionsPolicySchema` optional                  | —           | Inline policy rules (agent scope) |
| `welcomeMessage`| `string` optional                                   | —           | Shown on switch |
| `dispatchKind`  | `enum(["sub-agent","custom-agent","spec"])` optional | adapter default | Dispatch adapter selection (undocumented; corpus R-hooks-5) |
| `hooks`         | `hookDocumentSchema[]` optional                     | —           | Inline hooks, scoped to the active agent |

Body below the frontmatter = system prompt (`result.content.trim()`). NO
frontmatter at all → `parseCustomAgentFile` throws "No front matter found" →
profile dropped, recorded in the loader's `errors` array (logged
`[ProfileLoader] Failed to parse`). Because js-yaml CORE, `includeMcpJson: yes`
is the string `"yes"` → Zod boolean fails → whole profile dropped (loud in
logs, invisible in the UI).

### 3.2 Agent profiles — `.json` (`JsonAgentFileSchema`, byte 17210523)

Same keys as 3.1 plus `prompt: string.nullish()` (inline string or `file://`
URI, default `""`), and `tools` is `literal("*") | string[]` (NO comma-string
form — that is .md-only). JSON is parsed with `stripJsonComments` +
`trailingCommas: true` (JSONC accepted). `prompt: "file://<relative>"` is
resolved against the agent file's directory; absolute paths and `~` are
rejected; the realpath must stay inside the loading root (workspace root or
home) or the profile errors. `.md` prompts get NO `file://` resolution.

**CLI-only skip (exact mechanism, byte 17229916):** raw JSON keys are scanned
before schema parse; if any of `CLI_ONLY_FIELDS = ["allowedTools","toolsSettings"]`
is present and `permissions` (the sole `KAS_MARKER_FIELDS` entry) is `== null`,
the file is skipped with only a DEBUG log (`Ignoring CLI-only agent profile`).
A v2 config with `permissions` added parses as "universal". This check does not
exist for `.md` files (an .md with `allowedTools:` in frontmatter is a Zod
strict-object... no — the schema is a plain object, unknown keys are stripped
silently; the .md loads and `allowedTools` is ignored).

**Location resolution (byte 20361100, `loadFileBasedAgents`):** load order is
cloud-replica root → `~/.kiro/agents/` (scope user, unconditional) → bundled
definitions → each `<workspace>/.kiro/agents/` (ONLY if `workspaceTrusted`).
Later wins on id collision (`Duplicate agent ID ... overwriting` warn), so
workspace beats user beats cloud; builtin-mode ids are filtered from every
source. `findAgentFiles` (byte 17226827): recursive, entries sorted
`localeCompare`, symlinked files AND dirs followed via `stat` fallback, cycle
guard on realpath, broken symlinks skipped with warn; only `.md`/`.json`
extensions; agent id = path relative to the agents dir, separators normalized
to `/` (`team/planner.md` → `team/planner`), matching the vendor doc. A
`ConfigFileWatcher` on `.kiro/agents` invalidates the cache live (chokidar,
`.lock` ignored, debounced).

**Exposure:** user/workspace/cloud/client profiles become slash commands
(`isSlashCommandAgent`, byte 19424897); bundled profiles do not; builtin modes
only `context-gatherer` and `general-task-execution`.

### 3.3 Agent sub-schemas

**`PermissionsPolicySchema`** (byte 17206983): `{ rules: [{ capability: string,
match?: string[], exclude?: string[], effect: enum(allow|deny|ask) }],
policies?: string[] }` — `policies` references the 6 built-in presets (3.8).

**MCP wire fields** (byte 17199236+): common `env` (record string), `timeout`
(number ≥1, capped at `MAX_MCP_TIMEOUT_MS = 6e5`), `waitForReady` (bool),
`disabledTools` (string[]), `autoApprove` (string[]); stdio `command`, `args`,
`cwd`; http `url`, `headers`, `oauth {clientId?, redirectUri?}`, `oauthScopes`
(string[]); declaration `disabled` (bool), `type` (string — only `'registry'`
is acted on; transport hints accepted and ignored). `${VAR}` env expansion at
parse time; values starting `()` (bash function exports) are left unexpanded.
The vendor doc's `requestTimeout` field DOES NOT EXIST in this schema — the
only `requestTimeout` hits in the bundle are the vendored AWS smithy HTTP
client. It passes through the record and is never read (positive control:
`timeout` is read in `parseMcpServerConfig`).

**`AgentResources`** (byte 17213234): bare string `file://<path>` → context
file; `skill://<path>` → skill reference; other `scheme://` logged+dropped;
non-string entries → knowledge base object: `{ type: "knowledgeBase"
(literal), source: file:// URI (refined non-empty), name?, description?,
indexType?: enum(fast|best), include?: string[], exclude?: string[],
autoUpdate?: boolean }` (`autoUpdate: true` → "onAgentLoad", else "never").
`skill://` paths are resolved per workspace root + home
(`resolveSkillResources`, byte 19980911), each resolved file parsed as a
SKILL.md (name+description required or dropped with warn), then REGISTERED as
progressive-context items — i.e. profile skill resources do not force-inject
content; they add entries the model can disclose. Only for non-builtin modes.

### 3.4 Steering documents (`SteeringContextFrontMatterSchema`, byte 14723938)

| Key                | Type                                      | Default | Effect |
| ------------------ | ----------------------------------------- | ------- | ------ |
| `inclusion`        | `enum(["always","fileMatch","manual","auto"])` optional nullable | absent = always | Selection mode |
| `fileMatchPattern` | `string \| string[]` optional nullable    | —       | Globs for `fileMatch` (minimatch, `dot: true`, case-insensitivity probed per-FS) |
| `name`             | `string` optional                         | filename | Display/command name (consumed only on the progressive/command paths) |
| `description`      | `string` optional                         | —       | REQUIRED for `auto`; used as slash-command description for `manual`/`auto` |

Consumers and semantics:

- **Main source** (`NodeSteeringDocumentSource`, byte 19325435): scans each
  `<workspace>/.kiro/steering/` recursively (`.md` only, dirent-based —
  symlinked FILES are dropped here, no stat fallback), all global roots
  (`~/.kiro/steering/` always, cloud replica prepended at lower precedence),
  plus `AGENTS.md` at each workspace ROOT (forced `inclusion: always`, source
  `agents-md`; an AGENTS.md inside a steering dir is treated as a normal
  steering doc). Untrusted workspace → only `scope === "global"` docs survive
  (workspace steering AND AGENTS.md filtered).
- `always`/absent inclusion → injected into the `<steering-files>` block of the
  system prompt. `fileMatch` → doc injected when a context file matches;
  global docs match files in ANY workspace, workspace docs only their own
  root; match path is workspace-RELATIVE.
- **Frontmatter parse failure is caught and the doc loads RAW as
  always-included** — a typo like `inclusion: filematch` silently UPGRADES a
  scoped doc to always-on. This is the sharpest steering trap found.
- `manual` and `auto` docs become SLASH COMMANDS (byte 19424036,
  `createSteeringCommandSource`): command name = displayName, description =
  frontmatter `description`, `_meta.kiro.type = "steering"`.
- `auto` additionally routes through the **progressive-context scanner**
  (`NodeProgressiveContextSource`, byte 19381807): requires `description` (else
  dropped with warn), content held back until disclosed. This scanner DOES
  follow symlinked files and dirs (stat fallback + realpath cycle guard) — the
  opposite of the main steering scanner in the same engine.
- **Client-provided steering** (ACP extension, byte 19390780): array ≤100 of
  `{ name: min(1), inclusion: enum(always|fileMatch|manual) — NO "auto",
  fileMatchPattern?: string (required non-empty when fileMatch), content:
  string ≤1e6 }`; 1M char total budget, duplicates dropped, per-doc failures
  dropped not fatal.
- Steering doc set changes are pushed to the client via the
  `STEERING_DOCUMENTS_CHANGED_METHOD` extension notification with `auto` docs
  filtered out and inclusion coerced to `always|manual|fileMatch`.

### 3.5 Skills (`SkillFrontMatterSchema`, byte 14723938 region)

Schema: `{ name?, description?, license?, compatibility?, metadata?:
record(unknown) }.passthrough()`. All optional in the SCHEMA, but BOTH loaders
enforce `name` and `description` post-parse — missing either drops the skill
with a warn. `license`, `compatibility`, `metadata`, and any passthrough key
are carried on the item's `config` but no consumer beyond listing was found
(bounded: grepped `license`/`compatibility` consumers near both load sites).

Locations: one DIRECTORY per skill containing `SKILL.md` —
`~/.kiro/skills/<dir>/SKILL.md` (global; dir auto-created), each
`<workspace>/.kiro/skills/<dir>/SKILL.md` (workspace), cloud-replica skills dir
first (lowest precedence). Symlinked skill dirs ARE followed
(`entry.isDirectory() || entry.isSymbolicLink()`). Dedup is by **displayName
(frontmatter `name`), last wins** — workspace overrides global on name
collision regardless of directory name. Untrusted workspace → global-only
(trust filter applied in `ProgressiveContextManager.runScanAndCache`, byte
19378535). Content is frontmatter-stripped when disclosed.

Skills surface three ways: the `disclose_context` tool (bundle comment at byte
19312639: "disclose_context activates workspace/user .kiro/skills/ Skills (and
auto-inclusion steering)"), a slash command per skill
(`createSkillCommandSource`, description from frontmatter), and agent-profile
`skill://` resources (3.3). Skill activation is policy-gated by the `skill`
capability (`INFRASTRUCTURE_CAPABILITIES`).

### 3.6 Hooks (JSON, no frontmatter) — `hookDocumentSchema` (byte 13942653)

File format (`kasHookFileSchema`): `{ version: literal "v1", hooks: [ ... ]
min 1 }`. Per hook:

| Key           | Type                                       | Default | Effect |
| ------------- | ------------------------------------------ | ------- | ------ |
| `name`        | `string.min(1)` REQUIRED                   | —       | Telemetry/registry id |
| `description` | `string` optional                          | —       | Doc only |
| `trigger`     | `string.min(1)` REQUIRED                   | —       | Normalized via alias table; unknown name → hook dropped at load (warn + `hooks.unknownTrigger`) |
| `matcher`     | `string` optional (regex)                  | always-match | Compile failure → hook kept but NEVER matches (regex undefined + source set → false) |
| `action`      | `{type:"command",command:min(1)}` \| `{type:"agent",prompt:min(1)}` REQUIRED | — | discriminated union |
| `timeout`     | `int ≥ 0` optional (seconds)               | 60      | Vendor claims 0 disables; consumer semantics of 0 unverified |
| `enabled`     | `boolean` optional                         | `true`  | Skip without deleting |
| `confirm`     | `{question:min(1), options:[{id,label,run:boolean,continueReason?}] min 1, confirmCommand?:min(1)}` optional | — | UNDOCUMENTED; Stop-hook confirm gate; selected option id arrives as `user_decision` in the Stop stdin payload |

Trigger alias table (byte 13925211): canonical PascalCase `SessionStart Stop
PreToolUse PostToolUse PreTaskExec PostTaskExec UserPromptSubmit
PostFileCreate PostFileSave PostFileDelete Manual`; IDE camelCase aliases
`sessionStart agentStop promptSubmit preTaskExecution postTaskExecution
preToolUse postToolUse fileEdited fileCreated fileDeleted userTriggered`; CLI
aliases `agentSpawn stop userPromptSubmit`; Open-Plugin aliases `SessionEnd`→
Stop, `AfterFileEdit`→PostFileSave.

Matcher evaluation (byte 13943800, `hookMatchesTrigger`): regex tests tool NAME
for PreToolUse/PostToolUse, file PATH for PostFile*; for SessionStart, Stop,
UserPromptSubmit, PreTaskExec, PostTaskExec, Manual the matcher is IGNORED
(always true) — the vendor table claiming UserPromptSubmit matches prompt text
is wrong.

Loaders (three):

1. **Standalone** (`StandaloneHookLoader`): `<root>/.kiro/hooks/*.json`, FLAT
   (no recursion), `entry.type === "file"` filter (byte 13950319) so symlinked
   files are skipped; roots = every workspace root + global roots
   `[cloudHookRoot?, homeDir]` (so `~/.kiro/hooks/` loads); a workspace root
   whose hooks dir equals a global hooks dir is skipped (dedupe). Only the v1
   wrapper is accepted; schema failure → whole file rejected with warn.
2. **Agent-profile** (`AgentProfileHookLoader`): the inline `hooks:` array from
   3.1/3.2, ids `<profileId>#hook-<idx>`, active-agent scoped.
3. **Open Plugin** (`OpenPluginHooksLoader`, byte 13955000):
   `<workspace>/.agents/plugins/<plugin>/hooks/hooks.json` — Claude-Code-style
   `{ hooks: { <EventName>: [ { matcher?, hooks: [ {type:"command",command} |
   {type:"prompt",prompt} | {type:"agent",prompt} ] } ] } }`. `prompt` and
   `agent` both map to the Agent action; `${PLUGIN_ROOT}` and
   `${WORKSPACE_ROOT}` expand in command strings (the ONLY template expansion
   in any v3 hook path — standalone/profile hook commands get none; positive
   control: this expansion plus corpus R-hookio-1 stdin contract). Plugins
   sorted by name; workspace roots only, no global/home plugin dir.

`createHooksModule` hard-codes `featureFlags: { v2Hooks: true }`; triggers are
wired ONLY when `workspaceTrusted` (execution gate; loading always runs).
Hook cwd/env/stdin/decision semantics: corpus records (not re-derived).

### 3.7 Specs (structural markdown, NO frontmatter)

Authorable surface: `.kiro/specs/<kebab-name>/` with `requirements.md`,
`design.md`, `tasks.md` (constants at byte 14245265; layout confirmed by the
`FILE_NAMING_CONVENTION` prompt and vendor doc — they agree). No
`parseFrontMatter` call touches spec files (denominator in §2). The harness
parses `tasks.md` structurally (`parseTaskLine`, byte 15517142):

- Task line regex: `^(\s*)([-*+])\s+\[([ xX\-~])\](\\?\*?)\s+(.+)$`
- Checkbox status: space = not_started, `x`/`X` = completed, `-` = in_progress,
  `~` = queued (the `-` and `~` states are undocumented in the vendor doc).
- Optional-task marker: `*` or `\*` immediately after the checkbox.
- Task number extracted from leading `N.`/`N.N` text; numbered tasks terminate
  at the next task line, unnumbered ones nest by indentation.
- `_Requirements: x.y_` trailer lines are convention consumed by prompts, not
  by the line parser.

Spec task execution fires `PreTaskExec`/`PostTaskExec` hooks with
`spec_name`/`task_name` (+ `task_success` post) in the stdin payload.

### 3.8 Permissions files (YAML/JSON, whole-file)

Filenames: `POLICY_FILENAMES = ["permissions.yaml", "permissions.json"]` —
first existing wins per directory, so YAML shadows JSON; `.yml` is NOT probed
(parse branch accepts a `.yml` SUFFIX but no loader ever constructs one).

Locations/scopes (loader at byte 20111757; `SCOPE_ALLOWED_EFFECTS` byte
20093469):

| Scope          | Location                                                      | Allowed effects |
| -------------- | ------------------------------------------------------------- | --------------- |
| kiro           | hardcoded `KIRO_SCOPE_RULES` (byte 20060217)                  | deny, ask |
| administration | `/etc/kiro/managed-settings.json` (linux), `/Library/Application Support/Kiro/managed-settings.json` (darwin), `C:\ProgramData\Kiro\managed-settings.json` (win32) | deny, ask |
| user           | `~/.kiro/settings/permissions.yaml`                           | deny, ask, allow |
| workspace      | `~/.kiro/workspace-roots/<hash(workspaceRoot)>/permissions.yaml` (per-user, OUTSIDE the repo) | deny, ask, allow |
| agent          | `permissions:` block in the active agent profile              | deny, ask, allow |
| session        | runtime-provided                                              | deny, ask, allow |

File shape: `{ rules: [...], policies?: [preset-id...] }`. Rule fields exactly
`capability`, `effect`, `match?`, `exclude?` — an UNKNOWN FIELD in any rule
throws `PolicyParseError` and voids the ENTIRE file (fatal error, zero rules),
while an unknown CAPABILITY only skips that rule with a warning. Valid
capabilities (byte 4972280): `all builtin filesystem fs_read fs_write shell
web_fetch web_search mcp subagent skill power context diagnostics
sandbox_network` — the vendor table omits `power` and `sandbox_network`.
Presets (`policies:`): `allow-all`, `edit-workspace`, `dev-shell`, `read-all`,
`read-only-shell`, `read-workspace`; preset rules whose effect exceeds the
scope's allowance are skipped per-rule; unknown preset id skipped with warn.
Workspace-scope fs rules with patterns outside the workspace are skipped
(workspace-relative only). Baseline: writes to `~/.kiro/settings/`,
`.kiro/settings/`, `~/.kiro/workspace-roots/`, `~/.kiro/sandbox-state/` are
hard-denied; writes to `.kiro/agents/`, `.kiro/hooks/`, `**/*.code-workspace`,
`**/mcp.json`, `.kiroignore` always ask; without a user blanket fs-write allow
in an untrusted workspace, writes to `.kiro/{steering,skills,extensions,powers}`
get injected ask rules (autoload-content protection, byte 20062841).

Adjacent surface (context only): `mcp.json` at `~/.kiro/settings/mcp.json` and
per-workspace `.kiro/settings/mcp.json`, merged user < workspace1 < workspace2,
same wire schema as 3.3.

## 4. Activation drivers (who can pull each lever)

| Lever | Drivers |
| ----- | ------- |
| Agent profile file (.md/.json) | user-typed (slash command per profile), external-ACP-client (`session/new` mode, client-provided agents), model-elected (delegation tools when granted), agent-system-prompt-driven (custom-agent-creator writes profiles), workflow-step-driven (workflow agents resolve profiles) |
| `dispatchKind` / inline `hooks` in profile | takes effect whenever the profile is dispatched — same drivers as above; not directly user-callable |
| Steering `always` / `fileMatch` / AGENTS.md | harness-injected (no actor chooses; fileMatch keyed on context files) |
| Steering `manual` / `auto` | user-typed (generated slash command), external-ACP-client (sends the command); `auto` additionally model-elected via `disclose_context` |
| Skills | model-elected (`disclose_context`), user-typed (slash command), agent-system-prompt-driven (`skill://` resources register items) |
| Hooks (standalone + OP) | hook-driven by definition; `Manual` trigger is user-typed; loading is file-presence only; execution requires workspace trust |
| Specs (`tasks.md` etc.) | user-typed (`/spec ...`), model-elected (spec tools edit the files), workflow-step-driven (spec dispatch adapter), hook-driven observation (Pre/PostTaskExec) |
| Permissions files | user-authored only; agent writes to every policy store are hard-denied (kiro scope); agent-scope rules ride the profile |

## 5. Fixture designs (all are SPECS — no engine launch, no model calls)

Each fixture isolates `HOME` (the settled lever), seeds files, starts
`kiro-cli acp` with `--agent-engine=v3`, drives ONLY `initialize` +
`session/new` over stdio, and reads stderr logs + `available_commands_update` —
no prompt is ever sent.

1. **Frontmatter failure-mode matrix** (the discriminator): seed one file per
   surface with `inclusion: filematch` (bad enum), `includeMcpJson: yes`
   (CORE-schema string), SKILL.md missing `description`. PASS = agent profile
   absent from commands + `[ProfileLoader] Failed to parse` on stderr; steering
   doc present as ALWAYS-included (observable via `_kiro/session/context`);
   skill absent + `SKILL.md missing name or description` warn. FAIL = any
   surface behaving like another.
2. **CLI-only JSON skip**: two JSON profiles, `{allowedTools:[...]}` vs same +
   `permissions:{rules:[]}`. PASS = first absent with only a debug line,
   second present.
3. **Steering symlink asymmetry**: same target symlinked into
   `.kiro/steering/link.md` (with `inclusion: always`) and as an `auto` doc.
   PASS = main path drops it (absent from context), progressive path lists it
   (command appears).
4. **Hook trigger/matcher gate**: hooks file with unknown trigger, bad regex,
   `enabled: false`, and a `confirm` Stop hook. PASS = load-time warns for the
   first two (`hooks.unknownTrigger`, matcher compile warn), registry counts
   observable via logs; execution semantics stay corpus-covered (needs trust +
   turn → spec-only beyond load).
5. **Permissions file voiding**: rule with an extra key `comment: x`. PASS =
   fatal policy error, file contributes zero rules (observable: the
   `session/new` `_meta` policy error surface / stderr `[PolicyLoader]`), vs a
   sibling file with unknown capability that loses only the one rule.
6. **Skill name dedup**: global + workspace skill dirs with identical
   frontmatter `name`, different dir names. PASS = one command, workspace
   content wins.

## 6. Cross-interactions and traps

- **Same parser, three failure policies**: agent .md → profile DROPPED (loud);
  steering → doc KEPT raw as always-included (silent upgrade — the trap);
  SKILL.md → item DROPPED (warn). One typo class, three outcomes.
- Steering `name` collision across scopes: main source dedups by file URI (no
  cross-scope override), progressive/commands dedup by displayName last-wins —
  the SAME two files can both inject (always path) yet expose one command.
- `AGENTS.md` participates in steering but not in frontmatter parsing at the
  workspace root (loaded verbatim, forced always) — placing it INSIDE
  `.kiro/steering/` re-enables frontmatter handling.
- Hook `matcher` on the six always-match triggers is accepted and silently
  ignored (schema validates it; matcher table bypasses it).
- `permissions.yaml` silently shadows `permissions.json` in the same dir.
- Workspace trust cuts across surfaces differently: workspace agent profiles
  NOT LOADED; workspace steering/skills LOADED then filtered to global; hooks
  LOADED but execution disabled; permissions workspace scope unaffected (it
  lives under `~`, not in the repo).
- Vendor-doc discrepancies (beyond those inline): tags table lists `knowledge`
  and `todo_list` — neither is in `TAG_REGISTRY` (`read write shell web
  subagent spec context @mcp @powers @builtin @subagent @subagent-explicit`);
  the builtin creator prompt teaches `spec`/`@powers` which the doc omits;
  `requestTimeout` (3.3) unconsumed; UserPromptSubmit matcher/blocking claims
  contradicted (3.6 + corpus); `confirm`, `dispatchKind`, `effortLevel`,
  `excludedTools`, `name`, inline `hooks` all undocumented in the agent-config
  doc; exit-code table contradicted by the corpus raw-reader finding (inject on
  ANY exit code for SessionStart/UserPromptSubmit).
