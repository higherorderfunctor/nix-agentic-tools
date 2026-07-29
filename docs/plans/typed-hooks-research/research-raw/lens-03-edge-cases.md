# Hook Edge Cases & Gotchas Across Claude Code and Kiro CLI — Assessment for Typed-Options Design

## Scope & method

This section hunts edge cases and gotchas for the eventual "expose every hook as
typed Nix options" work, across **Claude Code** and **Kiro CLI v3 (primary) / v2
(defer)**. Evidence is graded **CONFIRMED** (primary source: official doc,
GitHub issue with maintainer status, or in-repo live-verified) vs **INFERENCE**
(derived, or from a secondary/summarized source). Where a source is a WebFetch
summary produced by a small model, I flag it as lower confidence because those
summaries confabulate per-event annotations — I cross-checked the load-bearing
claims against GitHub issues and the repo's own live-verified evidence.

The single most important framing result: **the user's flagged "Kiro doesn't
fire hooks in subagents" is not a Kiro-only quirk — Claude Code has the exact
same gap** (`anthropics/claude-code#34692`, closed _not planned_). This
symmetry, plus a pile of doc-vs-reality divergences, means a typed-options layer
cannot trust vendor docs as the schema-of-record; it must encode
empirically-verified behavior and stay soft/forward-compatible.

---

## 1. Subagent / Task execution (the flagged example, generalized)

**Both CLIs silently skip hook enforcement inside subagents. This is the
headline edge case and it is bilateral.**

- **Kiro — CONFIRMED.** `kirodotdev/Kiro#7755` ("Hooks should trigger in
  subagents — governance must be uniform") quotes Kiro's own docs: _"Hooks will
  not trigger in subagents."_ PreToolUse/PostToolUse/Stop all fail to fire for a
  subagent's own tool calls; only the main agent is governed. Opened 2026-04-23,
  unassigned, no fix. Recommended governance is the **subagent's own** config,
  not hooks: `availableAgents` / `trustedAgents` / `toolsSettings.subagent` and
  `allowedTools` in the subagent's agent file
  (`kiro.dev/docs/cli/chat/subagents/`). Kiro has **no
  `PreTaskExec`/`PostTaskExec` for arbitrary subagents** — those two v3 triggers
  fire only around **spec tasks** (`/spec run`), not general Task delegation
  (`docs/plans/kiro-v3-docs.txt:347-348,378`).
- **Claude — CONFIRMED.** `anthropics/claude-code#34692`
  ("PreToolUse/PostToolUse hooks do not fire for subagent (Agent tool) tool
  calls", affected 2.1.76+, **closed as not planned**): a `git commit` in the
  main thread fires the hook; the same command inside a subagent does not. The
  subagent lifecycle is instead covered by **`SubagentStop`** (and, per the
  current doc, a `SubagentStart`), which fire in the **parent** thread when the
  Task tool spawns/returns — i.e. you can observe _that_ a subagent ran, but you
  cannot gate the tools it used. `Stop` is explicitly **main-thread-only**.
- **Doc-vs-reality caution.** The current `code.claude.com/docs/en/hooks` page
  (via summarizer) annotates PreToolUse/PostToolUse as "fires in subagents
  (includes `agent_id`)." That **contradicts #34692** and I treat the per-event
  "fires in subagents" annotations as **unreliable summarizer output**; the
  closed issue is authoritative. The human should re-verify empirically on the
  target Claude version before relying on subagent-internal hooks either way.

**Design impact:** telemetry/memory/workflow consumers that assume hooks see
_all_ tool calls will silently under-count whenever work is delegated. A
typed-options layer should (a) document the subagent blind spot per event, and
(b) prefer `SubagentStop` (Claude) / spec `PreTaskExec` (Kiro) for
delegation-boundary telemetry rather than per-tool hooks.

---

## 2. Skill-scoped and agent-scoped hooks

| Capability                                                   | Claude Code                                                                                                                                                                                                                                                                                                                                      | Kiro CLI v3                                                                                                                                                                                                                                                                                                                      |
| ------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Hooks in **user/project settings**                           | Yes (`settings.json`) — CONFIRMED                                                                                                                                                                                                                                                                                                                | Yes (`.kiro/hooks/*.json`) — CONFIRMED                                                                                                                                                                                                                                                                                           |
| Hooks embedded in a **skill** (frontmatter)                  | **Yes** — CONFIRMED. "You register hooks in settings.json, managed policy settings, or **skill/agent frontmatter**" (`claude.com/blog/steering-…`). Same format as settings hooks; all hook types; **scoped to the skill's execution and cleaned up on exit**; **require user approval before first use** (secondary guides, medium confidence). | **No evidence.** `skill` is a _permission capability_, not a hook host; Kiro skills load globally but nothing indicates they embed hooks — INFERENCE: **not supported**.                                                                                                                                                         |
| Hooks embedded in a **locally-authored agent** (frontmatter) | **Yes** — CONFIRMED (same steering-blog sentence: "skill/agent frontmatter").                                                                                                                                                                                                                                                                    | v2 supported **embedded hooks in agent config**; v3 moved them to standalone files but "existing embedded hooks in agent configs still work during the transition" and `kiro-cli agent migrate` converts (`kiro-v3-docs.txt:306,547`). So v3 agents _can_ still carry embedded hooks transitionally — CONFIRMED, but deprecated. |
| Hooks embedded in a **plugin-shipped agent**                 | **NO — blocked for security.** "For security reasons, `hooks`, `mcpServers`, and `permissionMode` are **not supported** for plugin-shipped agents" (`plugins-reference:72`). Plugin _skills_ and top-level `hooks/hooks.json` can carry hooks; plugin _agents_ cannot.                                                                           | N/A (Kiro has no plugin-agent concept).                                                                                                                                                                                                                                                                                          |
| Does skill **activation** fire a hook?                       | No dedicated "SkillActivated" event; activation _installs_ the skill's frontmatter hooks for its lifetime and tears them down on exit. `InstructionsLoaded`/`ConfigChange:skills` may fire (doc, low confidence).                                                                                                                                | No.                                                                                                                                                                                                                                                                                                                              |

**Design impact — load-bearing asymmetry:** the repo already ships agents/skills
as first-party Nix packages (`mkSkillPackageModule`,
`packages/stacked-workflows/skills/…`) and via plugins. **If a hook is attached
to a plugin-shipped agent, Claude will reject/ignore it.** The typed-options
layer must decide _where_ a hook lives (settings vs skill frontmatter vs plugin
`hooks.json` vs agent frontmatter) because the delivery channel changes whether
the hook is even legal. This is a genuine composition constraint, not just
cosmetics.

---

## 3. TUI vs headless / print mode

- **Kiro v3 hooks are effectively TUI-only — CONFIRMED.** v3 known-gaps:
  _"Classic mode not supported — the legacy non-TUI mode (`kiro-cli chat`
  without the TUI) does not support the v3 engine. Use the TUI."_
  (`kiro-v3-docs.txt:52-53`). In-repo memory `project_kiro_hook_engine_split`
  records live 2.12.0: **v3 hooks fire only in the TUI engine**; `Stop` is
  per-turn; hook stdin is metadata. Consequence: a headless/CI Kiro invocation
  that isn't on the v3 TUI engine runs _no_ v3 hooks. There is **no per-trigger
  TUI/headless matrix in the docs** — this is empirically-derived, so flag it
  for re-verification per version.
- **Claude headless `-p`/print mode fires hooks — CONFIRMED for Stop.** The
  repo's `validate-at-stop` POC ran end-to-end under `claude -p` in a scratch
  repo (2026-07-17): "Stop fires at hand-back; the
  `{"decision":"block","reason":…}` channel reaches the model;
  `stop_hook_active` flips true on the continuation"
  (`docs/plans/prek-stop-hook-validator.md:30-35`). The current doc also
  describes `-p`-specific behavior: `UserPromptSubmit` stdout is added to the
  transcript; `SessionStart`'s `initialUserMessage` **only** applies in `-p`
  mode; a `Setup` event exists specifically for `--init`/`--maintenance` in `-p`
  (doc, medium confidence). So Claude hooks are usable headless; Kiro v3 hooks
  largely are not.

**Design impact:** the "checks/fixtures verify every hook" goal is far more
tractable for Claude (headless is a first-class path — the
`validate-at-stop.nix` stub-tool pattern already proves hermetic verification)
than for Kiro v3 (TUI-gated → live verification needs a real TUI harness like
`dev/scripts/kiro-memory-hitl.sh`, which is manual/HITL, not `nix flake check`).

---

## 4. Lifecycle asymmetries (the ones a shared abstraction must reconcile)

| Concern           | Claude Code                                                                                                                                         | Kiro CLI v3                                                                                                                                                                                                                                                                                                                                                |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| End-of-turn event | `Stop` (main thread) fires when Claude finishes responding — **can block** (exit 2 / `decision:block`) to force a continue → **loop risk**          | `Stop` fires **per turn** (not session end) — **cannot block** (v3 table: "Can block? No")                                                                                                                                                                                                                                                                 |
| Loop guard        | `stop_hook_active` field (CONFIRMED live in-repo POC; the settings-doc summary omitted it — trust the repo). Persistent block would loop without it | Not needed — Stop can't block, so no continue-loop                                                                                                                                                                                                                                                                                                         |
| Session end       | **`SessionEnd`** exists (end_reason: clear/resume/logout/…)                                                                                         | **NO SessionEnd / no on-exit hook** — CONFIRMED (in-repo D11/D24; absent from v3 trigger list). This is _the_ hard constraint that forced the auto-memory design to debounce + cross-session tail-flush on next `SessionStart`                                                                                                                             |
| Session start     | `SessionStart` (source: startup/resume/clear/compact)                                                                                               | `SessionStart` (v3; was `agentSpawn` in v2). Matcher **not evaluated**                                                                                                                                                                                                                                                                                     |
| Subagent end      | `SubagentStop` (parent thread)                                                                                                                      | none for general subagents; `PostTaskExec` only for **spec** tasks                                                                                                                                                                                                                                                                                         |
| Compaction        | `PreCompact` (CONFIRMED) + advertised `PostCompact`                                                                                                 | none                                                                                                                                                                                                                                                                                                                                                       |
| Doc inconsistency | —                                                                                                                                                   | **Kiro's v3 hooks page calls `Stop` "Session ends"** (`kiro-v3-docs.txt:344`) while Kiro's **general** hooks page (`kiro.dev/docs/cli/hooks/`) says `Stop` "Runs when the assistant finishes responding to the user (**at the end of each turn**)". The general page + live evidence win: **per-turn**. A typed layer must not surface the v3-page wording |

**Design impact:** a naive "Stop = session end, do end-of-session work here"
mapping is wrong on **both** CLIs for different reasons (Claude Stop is
per-turn-of-the-main-agent and re-entrant; Kiro Stop is per-turn with no
session-end backstop at all). Memory/telemetry consumers that want a true
session-end signal have it only on Claude (`SessionEnd`); on Kiro they must
emulate it (debounce + `SessionStart` flush), exactly as `autoMemory.nix`
already does.

---

## 5. Discovery quirks (workspace vs global, symlinks, precedence)

- **Kiro v3 hooks are WORKSPACE-LOCAL and must be REAL files — CONFIRMED
  (in-repo, load-bearing).** v3 discovers hooks **only** under the launch cwd's
  `.kiro/hooks/` — never global `~/.kiro/hooks/` — and its `read_dir` scan
  **skips store symlinks** (`packages/kiro-cli/lib/autoMemory.nix` header +
  rules fragment; issues `kirodotdev/Kiro#5440/#7737/#9075`). Two hard
  consequences already baked into the repo: **(a)** the HM global install of
  `ai.kiro.hooks` (`~/.kiro/hooks/`) is **dead for v3** (kept only as source of
  truth); **(b)** the devenv backend must
  `install -m 0644 <writeText> .kiro/hooks/<name>.json` as a **real file in
  `enterShell`**, not a devenv `files.*` symlink. Steering/agents load fine as
  symlinks; **only hooks** need the real-file copy.
- **Kiro permissions gate hook edits — CONFIRMED.** The hardcoded Kiro scope
  **"Always asks"** on writes to `.kiro/hooks/**`, `.kiro/agents/**`, `.git/**`
  (`kiro-v3-docs.txt:228`). So a hook that rewrites another hook, or an agent
  editing `.kiro/hooks/`, will prompt.
- **Claude discovery & precedence — CONFIRMED (doc, medium).** Sources:
  `~/.claude/settings.json` (user) < `.claude/settings.json` (project) <
  `.claude/settings.local.json` (local, gitignored) < plugin `hooks/hooks.json`
  < skill/agent frontmatter < **managed/enterprise policy** (highest;
  `allowManagedHooksOnly` can suppress user/project/plugin hooks). **Hooks
  COMPOSE additively (union), not last-wins override** — all matching hooks from
  all sources run in parallel, and **identical command+args are deduplicated**.
  Plugin hooks targeting the plugin's own MCP server must use **scoped matcher
  names** `mcp__plugin_<plugin>_<server>__<tool>` (a bare-name matcher never
  fires) and `mcp_tool.server = plugin:<plugin>:<server>`.
- **Monorepo / nested config:** Claude reads the nearest `.claude/` up the tree
  plus user + policy; Kiro v3 keys strictly on **launch cwd** `.kiro/`. For
  worktrees, the repo's `deriveProjectId` (git-common-dir → main repo root)
  deliberately shares memory across worktrees, but **each worktree needs its own
  materialized `.kiro/hooks/`** — the per-workspace delivery gap is an open
  backlog item for non-Nix repos.

**Design impact — this is the biggest gotcha for the Nix factory.** The blanket
Nix standard "write config as store symlinks" is _actively wrong_ for Kiro v3
hooks. The typed-options layer must special-case Kiro hooks to real-file
materialization (HM can't do it for v3 at all → HM route is documentation-only
for v3; devenv real-file copy is the live path). Claude's additive-union
composition also means the layer cannot model "one hook per event slot" — it
must support many hooks per event and expect merge with hooks from
plugins/skills/policy it doesn't own.

---

## 6. Runtime env, PATH, cwd, timeouts, exit codes

- **"MCP env REPLACES process env → bare commands break" — CONFIRMED for Claude
  (in-repo, load-bearing).** `claude-rules-nix-standards`: Claude Code's MCP
  `env` field _replaces_ the process environment; a wrapper spawned with a
  stripped env has **no PATH**, so bare `cat`/`jq`/`git` become
  `command not found` and secrets fail **silently**. Every generated hook
  wrapper must use **absolute store paths** (`${pkgs.coreutils}/bin/cat`,
  `lib.getExe`), bash builtins excepted. This is why `autoMemory.nix` and
  `validate-at-stop.nix` use `getExe'`/`runtimeInputs` throughout. For **Kiro**
  hook subprocesses the same stripped-PATH risk is **INFERENCE** (not separately
  documented), but the repo already mandates absolute paths for _all_ wrappers,
  so the mitigation is identical and already in force.
- **Timeouts diverge by CLI and by Kiro version — CONFIRMED:**
  - Claude: per-hook `timeout` in **seconds**; default cited as 60s
    historically, doc now cites larger per-event defaults (UserPromptSubmit 30s,
    most 600s) — treat exact numbers as medium confidence and read them from the
    target version.
  - Kiro **v3**: `timeout` in **seconds**, default **60**, **`0` disables**,
    **ignored for `agent` actions** (`kiro-v3-docs.txt:391`).
  - Kiro **v2**: `timeout_ms` in **milliseconds**, default **30000**
    (`kiro.dev/docs/cli/hooks/`). The field name _and_ unit differ between v2
    and v3 — a typed schema cannot share one `timeout` field across engine
    versions.
- **On timeout / non-zero exit — CONFIRMED:**
  - Claude: exit `0` success (stdout may become context); exit `2` =
    **blocking**, stderr fed **to the model**; any other non-zero =
    **non-blocking**, stderr to the **user only**, execution proceeds. (This
    exact contract is why the old prek PostToolUse hook was invisible to the
    model — prek exits `1`, never `2`;
    `docs/plans/prek-posttooluse-hook-feedback-channel.md:57-98`.)
  - Kiro v3: exit `0` (stdout→context for SessionStart/UserPromptSubmit, ignored
    elsewhere); exit `2` blocks **PreToolUse/UserPromptSubmit only**,
    stderr→LLM; **any other exit = warning to user, execution proceeds**
    (`kiro-v3-docs.txt:394-402`).
- **Concurrency — CONFIRMED (Claude):** all matching hooks run in **parallel**,
  dedup by identical command. Kiro: one `.kiro/hooks/*.json` envelope can carry
  **many** hooks and **multiple files all load** (in-repo D30: "kiro fires 3+
  hooks from one file live"); ordering/parallelism across Kiro hooks is
  undocumented.
- **cwd:** both feed `cwd` on stdin; the repo's `validate-at-stop.sh` and the
  auto-memory distiller both `cd "$cwd"`/derive paths from it rather than
  trusting the process cwd.

---

## 7. stdin schema divergence a shared abstraction must reconcile

| Field concept     | Claude Code                                                                        | Kiro v3                                                                                                                                                                                  | Reconciliation risk                                                                 |
| ----------------- | ---------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| Common            | `session_id`, `transcript_path`, `cwd`, `hook_event_name`, `permission_mode`       | `session_id`, `cwd`, `hook_event_name` (**metadata-only in practice**)                                                                                                                   | Kiro gives far less; no `transcript_path`                                           |
| Tool events       | `tool_name`, `tool_input`, `tool_output`/`tool_response` (+ advertised `agent_id`) | `tool_name`, `tool_input`, `tool_response`                                                                                                                                               | Roughly aligned                                                                     |
| Prompt event      | `UserPromptSubmit.user_input` / `prompt`                                           | `UserPromptSubmit.prompt` **documented but EMPTY live** (in-repo D12)                                                                                                                    | **Load-bearing divergence**                                                         |
| Turn end          | `Stop.last_assistant_message`, `stop_reason`, `stop_hook_active`                   | `Stop.assistant_response` **documented but EMPTY live** (in-repo D23)                                                                                                                    | Kiro's richer-looking Stop payload is not populated on the tested versions          |
| Transcript access | via `transcript_path`                                                              | **not provided** → the distiller must **glob `~/.kiro/sessions/<hash>/<sid>/messages.jsonl` itself** and parse typed-event JSONL where the discriminator is `payload.type` (in-repo D23) | Kiro hooks that need conversation content must read disk; Claude hands you the path |

**Design impact:** the documented Kiro stdin schema **overstates** what actually
arrives (`prompt` and `assistant_response` come through empty on 2.11/2.12). A
typed-options design that exposes those fields as if populated will mislead
every downstream consumer (memory recall can't key on the user's prompt — the
repo's `recall` hook works around this by seeding the archive query from
`now.md`, not the empty `prompt`). Model Kiro hook stdin as **metadata-only**
and treat any richer field as best-effort/version-gated.

---

## 8. Version-specific behavior

- **Kiro 2.11 / 2.12 (live in-repo):** Stop per-turn; stdin metadata-only;
  workspace-local hooks; store-symlinks skipped; no SessionEnd; v3 hooks
  TUI-only. All CONFIRMED via the auto-memory implementation and
  `project_kiro_hook_engine_split` / `project_kiro_v3_hooks_workspace_local`.
- **Kiro v2→v3 schema break (CONFIRMED):** embedded→standalone files;
  **PascalCase** triggers (`stop`→`Stop`, `agentSpawn`→`SessionStart`,
  `fileEdited`→`PostFileSave`, …); `toolsSettings`→`permissions`; **new**
  triggers `PreTaskExec`/`PostTaskExec`/`PostFileDelete`/`Manual`;
  `timeout_ms`(ms)→`timeout`(s). `kiro-cli agent migrate` auto-converts. Two
  action types in v3: **`command`** (subprocess, stdin JSON) and **`agent`**
  (appends a prompt string to context, **no subprocess**, timeout ignored).
- **Claude recent (2.1.76+):** subagent tool-hook gap (#34692). The current doc
  advertises a **much larger event surface** than the classic nine —
  `SessionEnd`, `PreCompact`, `SubagentStop` are CONFIRMED-stable; a long tail
  (`SubagentStart`, `PostToolUseFailure`, `PostToolBatch`, `Notification`
  subtypes, `PreCompact`/`PostCompact`, `Setup`, `UserPromptExpansion`,
  `PermissionRequest/Denied`, `MessageDisplay`, `CwdChanged`, `FileChanged`,
  `WorktreeCreate/Remove`, `Elicitation*`, `ConfigChange`, `InstructionsLoaded`,
  `TaskCreated/Completed`, `TeammateIdle`, `StopFailure`) is **advertised by the
  summarized doc but UNVERIFIED** and possibly version-gated. **Do not hard-code
  this list.**

---

## 9. Consolidated edge-case table

| #   | Edge case                                                                                              | CLI                     | Confirmed? (source)                                              | Impact on typed-options design                                     | Mitigation                                                                                                                                |
| --- | ------------------------------------------------------------------------------------------------------ | ----------------------- | ---------------------------------------------------------------- | ------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Hooks don't fire for subagent-internal tool calls                                                      | Both                    | CONFIRMED (Kiro #7755 + doc; Claude #34692 closed _not planned_) | Per-tool hooks under-govern delegated work; telemetry under-counts | Document blind spot per event; use `SubagentStop`/spec `PreTaskExec` for boundary signals; govern subagents via their own tool allowlists |
| 2   | `Stop` is per-turn, not session-end                                                                    | Kiro                    | CONFIRMED (general hooks doc + in-repo D11)                      | "do session-end work in Stop" is wrong                             | Model Stop as per-turn; emulate session-end via debounce + SessionStart                                                                   |
| 3   | v3 hooks page mislabels Stop as "Session ends"                                                         | Kiro                    | CONFIRMED (v3 doc vs general doc contradiction)                  | Doc is not schema-of-record                                        | Encode empirically-verified semantics, not v3-page wording                                                                                |
| 4   | No `SessionEnd` / on-exit hook at all                                                                  | Kiro                    | CONFIRMED (in-repo D24; absent from trigger list)                | No place to flush at session close                                 | Cross-session tail-flush on next SessionStart (already done)                                                                              |
| 5   | Hook stdin metadata-only; `prompt`/`assistant_response` empty despite docs                             | Kiro                    | CONFIRMED (in-repo D12/D23)                                      | Consumers can't key on prompt/response text                        | Read transcript off disk; seed recall from buffer not prompt                                                                              |
| 6   | v3 hooks workspace-local only; global `~/.kiro/hooks` ignored                                          | Kiro                    | CONFIRMED (in-repo + #5440/#7737/#9075)                          | HM global install is dead for v3                                   | Real-file materialization in workspace `.kiro/hooks/` (devenv `enterShell`)                                                               |
| 7   | v3 `read_dir` skips store symlinks                                                                     | Kiro                    | CONFIRMED (in-repo)                                              | Standard Nix symlink delivery silently yields 0 hooks              | Copy real files (`install -m 0644`), never `files.*` symlink                                                                              |
| 8   | v3 hooks TUI-only (classic/headless non-TUI can't run v3 engine)                                       | Kiro                    | CONFIRMED (v3 known-gaps + in-repo memory)                       | Headless verification impossible on v3                             | TUI HITL harness for live checks; `nix flake check` can only hermetically stub                                                            |
| 9   | v2↔v3 schema break (PascalCase triggers; `timeout_ms` ms → `timeout` s; embedded→standalone)           | Kiro                    | CONFIRMED (v3 docs)                                              | One shared field set can't span engines                            | Version-gate the schema; v2 = stub-only per project scope                                                                                 |
| 10  | `agent` action type has no subprocess, ignores `timeout`                                               | Kiro                    | CONFIRMED (v3 docs)                                              | `timeout`/`command` options are invalid for agent actions          | Model action as a tagged union (command vs agent)                                                                                         |
| 11  | Stop cannot block (no force-continue)                                                                  | Kiro                    | CONFIRMED (v3 trigger table)                                     | No Kiro analogue to Claude's Stop-block-to-fix                     | Don't offer a "block on Stop" option for Kiro                                                                                             |
| 12  | Stop can block → infinite-loop risk; guarded by `stop_hook_active`                                     | Claude                  | CONFIRMED (in-repo POC + validate-at-stop.sh)                    | Any blocking Stop hook needs a loop guard                          | Ship the `stop_hook_active` guard pattern; typed helper for it                                                                            |
| 13  | `Stop` main-thread-only; subagents use `SubagentStop`                                                  | Claude                  | CONFIRMED (doc)                                                  | Two distinct events to expose                                      | Separate `Stop` / `SubagentStop` option slots                                                                                             |
| 14  | Skill/agent frontmatter can embed hooks (scoped, need approval)                                        | Claude                  | CONFIRMED (steering blog)                                        | A hook may live in a skill/agent, not settings                     | Support hook attachment per delivery channel                                                                                              |
| 15  | **Plugin-shipped agents CANNOT embed `hooks`/`mcpServers`/`permissionMode`** (security)                | Claude                  | CONFIRMED (plugins-reference:72)                                 | Hook on a plugin agent is silently illegal                         | Route agent hooks via settings/skill; validate at eval time                                                                               |
| 16  | Hooks compose **additively (union)** across user/project/local/plugin/skill/policy; identical dedup    | Claude                  | CONFIRMED (doc)                                                  | Not last-wins; can't model one-hook-per-slot                       | Many-hooks-per-event lists; expect foreign hooks to co-run                                                                                |
| 17  | Managed/enterprise policy can suppress user/project/plugin hooks (`allowManagedHooksOnly`)             | Claude                  | CONFIRMED (doc, medium)                                          | A generated hook may be silently disabled                          | Document; don't assume our hooks always run                                                                                               |
| 18  | Plugin MCP-tool matcher needs scoped name `mcp__plugin_<p>_<s>__<t>`                                   | Claude                  | CONFIRMED (plugins-reference:154)                                | Bare-name matcher never fires                                      | Auto-scope matchers when emitting into a plugin                                                                                           |
| 19  | MCP `env` **replaces** process env → bare commands break (no PATH), secrets fail silently              | Claude (Kiro: inferred) | CONFIRMED Claude (nix-standards); INFERENCE Kiro                 | Every wrapper needs absolute store paths                           | `getExe`/`runtimeInputs`; already enforced by `checks/bare-commands.nix`                                                                  |
| 20  | Headless `-p` fires hooks (Stop verified)                                                              | Claude                  | CONFIRMED (in-repo POC)                                          | Hermetic + headless verification is feasible                       | Reuse `validate-at-stop.nix` stub-tool pattern for all Claude hooks                                                                       |
| 21  | Matcher: exact-vs-regex heuristic, unanchored regex                                                    | Claude                  | CONFIRMED (doc)                                                  | Naive regex assumption is wrong; `Bash` ≠ regex                    | Model matcher as string; document anchoring; test fixtures                                                                                |
| 22  | Matcher target varies by trigger (tool name vs file path vs prompt text); some triggers ignore matcher | Kiro                    | CONFIRMED (kiro-v3-docs:371-378)                                 | Matcher validity is per-trigger                                    | Per-event matcher typing; forbid matcher where ignored                                                                                    |
| 23  | Event surface is large & volatile (≫ classic 9; long tail advertised/unverified)                       | Claude                  | CONFIRMED core; INFERENCE tail                                   | Hard enum goes stale fast                                          | Soft-enum (`either (enum known) str`), sidecar-fed like `models.json`                                                                     |
| 24  | Kiro "Always asks" on writes to `.kiro/hooks/**`, `.kiro/agents/**`                                    | Kiro                    | CONFIRMED (v3 permissions doc)                                   | Self-modifying/hook-editing hooks prompt                           | Document; keep hooks immutable post-materialization                                                                                       |
| 25  | Some hooks require an authenticated CLI (burn tokens)                                                  | Both                    | CONFIRMED (task premise + in-repo HITL pattern)                  | Can't run in `nix flake check`                                     | Env-gated flake app / devenv task for live hooks; hermetic stub for logic                                                                 |

---

## 10. What this means for the eventual typed-options design (synthesis)

1. **Two vendors, two philosophies, one abstraction is leaky.** Claude =
   additive-union hooks across many scopes, rich stdin, headless-friendly,
   huge/volatile event set, `exit 2`=block-to-model. Kiro v3 = single workspace
   dir, metadata-only stdin, TUI-gated, small fixed trigger set, `agent` vs
   `command` action union, no session-end, Stop can't block. A shared
   "per-event, matcher-aware" schema should be **CLI-namespaced**
   (`ai.claude.hooks.<Event>` / `ai.kiro.hooks.<Trigger>`) with only thin shared
   plumbing — do **not** try to unify the event set.
2. **Soft enums, sidecar-fed.** Mirror the existing `models.json`/`engines.json`
   pattern: known events in a committed JSON sidecar,
   `types.either (enum known) str`, so a new Claude event or Kiro trigger never
   breaks eval. Never `types.anything` (nix standard).
3. **Kiro hook materialization is the sharp edge.** The generic Nix "symlink
   from store" delivery is wrong for Kiro v3; the typed layer must force
   real-file copy into workspace `.kiro/hooks/`, and must document that the **HM
   route is v3-dead** (devenv is the only live path). Claude hooks stay
   symlink/settings-writable as today.
4. **Composition/precedence must be modeled, not assumed.** Claude hooks union
   with plugin/skill/agent/policy hooks the factory doesn't own; the typed layer
   should emit lists and rely on Claude's dedup, and validate that plugin-agent
   hooks are rejected before shipping them.
5. **Verification split is real.** Logic tests (no live CLI) are cheap and
   already proven (`validate-at-stop.nix` stub-tool + stdin-payload pattern;
   `checks/module-eval.nix` for materialization/parity). Hooks that need an
   authenticated CLI must be **manual/env-gated** — most credibly a **flake app
   or devenv task** (not `nix flake check`), because Kiro v3's TUI-gating means
   even a "live" check can't be headless. `nix flake check` should cover:
   schema→JSON rendering, real-file-vs-symlink materialization, HM↔devenv
   parity, matcher/trigger validity, absolute-path wrapper linting — everything
   except the actual token-burning fire.
