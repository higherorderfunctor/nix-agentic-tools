# Typed Hooks Across Claude Code & Kiro CLI — Lay-of-the-Land Assessment

> **Status:** research / lay-of-the-land only. No design committed, no code
> written. **Date:** 2026-07-20 · **Branch:** `refactor/ai-factory-architecture`
> **Triage status:** decisions triaged (§13) and hermetic facts confirmed; all
> `[U]` / version-contingent facts (§12 Qs 1–4) are **pending a one-time live
> probe — verify once implemented**. This is a plan of record, not
> verified-in-production truth. **Primary-source hardening pass (2026-07-20b):**
> the full Claude I/O contract for the PoC events (stdin, JSON output, exit
> codes, decision fields, timeouts, matchers) is now pinned to a hashed raw
> `code.claude.com/docs/en/hooks.md` snapshot + the anthropics reference impl,
> and the four named GitHub issues were re-read. See
> **[§18](#18-primary-source-hardening-pass-2026-07-20b)** for the upgrade
> ledger and `docs/plans/typed-hooks-research/primary-source-hardening.md` for
> the citation store. Net: several §4 facts moved to firmly-cited `[C]`; the
> subagent-tool question (§12 Q3) stays `[U]` but is now _bracketed_ by primary
> sources; the timeout default is **corrected to 600 s**. **Goal being scoped:**
> expose _every_ available Claude Code and Kiro CLI hook as **typed** Nix
> options in the `ai.*` factory (HM + devenv), with per-hook verification,
> composition/precedence handling, and edge-case coverage. **Method +
> provenance:** see [§14](#14-provenance--method). Every non-obvious claim
> carries an inline source. Facts are tagged **[C]** confirmed against a primary
> source (vendor docs, the actual binary, or in-repo code read this session),
> **[U]** uncertain / version-contingent, **[R]** a claim an adversarial
> verifier refuted or corrected. Where sources disagree, the disagreement is
> shown, not hidden.

---

## 1. Executive summary

Today both CLIs' hooks are **untyped passthrough**: `ai.claude.hooks` is
`attrsOf lines` (raw script bodies written as files — the event→matcher wiring
lives in the _freeform_ `ai.claude.settings.hooks` JSON), and `ai.kiro.hooks` is
`attrsOf (either lines path)` (whole-file raw JSON envelopes). The `mkKiro.nix`
source comments already say the Kiro side _should_ be modeled typed "like
`permissions`". This assessment maps the full hook surface of both CLIs, the
composition/precedence rules, the edge cases, a verification strategy, and a
drift-detection + provenance mechanism, then ends with the decisions needed from
you and a recommended phasing.

**Headline findings**

1. **Claude's hook surface is huge and version-drifting.** The current docs
   (`code.claude.com/docs/en/hooks`) document **33 events** across **5 handler
   types** (`command`/`http`/`mcp_tool`/`prompt`/`agent`); the compiled binary
   embeds **30** event-name literals. The "classic 9" everyone remembers is a
   small subset. **[C]**
2. **Kiro's trigger set is genuinely contested across three sources** (5 vs 11
   vs ~6-in-binary — see
   [§5.1](#51-the-trigger-set-is-contested-read-this-first)). This is not a
   research error; the vendor ships two doc pages that disagree, and the binary
   agrees with neither. **This single fact is the strongest argument for the
   drift detector you asked for.** **[C]**
3. **Upstream `programs.claude-code.hooks` is a _typed_ option**
   (`attrsOf lines` = script files) — but it carries **no event and no
   matcher**; the wiring is freeform. So typing events means _we_ generate the
   `settings.hooks` JSON. **[C, R]** (a lens claimed it was "freeform
   passthrough"; the verifier corrected it — it is typed, just script-only.)
4. **A real latent bug exists today:** `mkClaude.nix:507` merges two
   incompatible shapes into devenv's `claude.code.hooks`, which is masked only
   because the module-eval check stubs that option as `attrsOf anything`. In a
   real devenv eval it is a type error. **[C]** — actionable regardless of the
   typed refactor.
5. **Subagent firing diverges by CLI:** Kiro's own docs say hooks **do not fire
   in subagents**; Claude **does** fire agentic-loop hooks in subagents (stdin
   carries `agent_id`) — though a closed Claude issue (#34692) muddies the
   version story. The "both fail" framing is wrong. **[C, R]**
6. **`nix flake check` cannot verify live hook firing.** Checks are
   sandboxed/pure (no network, no auth) — so a token-burning "does this hook
   actually fire?" test **must** live outside the check set (flake app / devenv
   task / HITL harness). Hermetic tiers (emission golden-tests + stub-driven
   contract tests) cover everything else. **[C]**
7. **Composition needs no script concatenation.** Both CLIs **union** all
   matching hooks for an event and run them; Nix just emits array/attrset
   entries and lets the CLI aggregate. The shebang-concat problem is a
   non-problem. **[C]**

---

## 2. Why (goal + the three future plans)

**Immediate:** make hooks easy to configure typed-in-Nix, with validation,
HM+devenv parity, and composition that doesn't silently clobber.

**The three future plans that will be _built on top of_ these options** (they
must be wireable purely in Nix, no later code changes):

| Plan                              | Hook events it needs                                                                                  | stdin fields it reads                                                              | output fields it needs                                    | Precedent                                                                        |
| --------------------------------- | ----------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- | --------------------------------------------------------- | -------------------------------------------------------------------------------- |
| **Telemetry** on hook fire        | any/all events (fire-and-forget)                                                                      | event name, ids, timing                                                            | **none** — exit 0, no stdout, no block; can run `async`   | new                                                                              |
| **Memory** auto record/inject     | write: `Stop`, `SessionStart`; inject: `UserPromptSubmit` (+ Claude `SessionStart.additionalContext`) | Claude: `transcript_path`, `prompt`; Kiro: metadata-only + self-located transcript | `additionalContext` / stdout-to-context                   | **shipped** on Kiro: `packages/kiro-cli/lib/autoMemory.nix`                      |
| **Turn / tool-call minimization** | `PreToolUse` (gate/rewrite), `PostToolUse` (`additionalContext`), `UserPromptSubmit`                  | `tool_name`, `tool_input`                                                          | `permissionDecision`, `updatedInput`, `additionalContext` | `docs/plans/skill-bootstrap-context-injection.md`, `prek-stop-hook-validator.md` |

Key implication: **telemetry works on the widest surface with zero output
contract; memory + turn-min require the _output envelope_ (inject/decision) to
be typed.** A design that only types the `command` string (like devenv's
`claude.code.hooks` does) is insufficient for two of the three plans. **[C]**
(`section_07`, corroborated by the Claude output-contract in
[§4](#4-claude-code-hook-inventory-authoritative)).

---

## 3. Current state in-repo

### 3.1 Claude (`packages/claude-code/lib/mkClaude.nix`) — ✅ LANDED (Claude slice C1–C6b, origin @ `b5f7f74f`)

> **The bullets below are the now-accurate post-slice state** (typed hooks
> shipped 2026-07-20d; full record:
> `docs/plans/claude-typed-hooks-implementation.md`). The pre-slice state —
> untyped `attrsOf lines`, event-wiring riding freeform `settings.hooks`, and
> the latent devenv `//` mis-feed
> (`claude.code.hooks = (settings.hooks) // cfg.hooks`, masked by the
> `attrsOf anything` stub) — is preserved in the git history at `eadaa023` and
> in the closeout §2.

- **`ai.claude.hooks` = typed per-event map**
  `attrsOf (listOf { matcher?; hooks = listOf handler })`. `<Event>` is a **soft
  enum** `either (enum knownEvents) str` sourced from the extracted **30-event
  `hookEvents`** key in `overlays/claude-code-extracted.json` (never
  hard-coded). A handler `command` is **S1 store-backed**
  (`coercedTo package (getExe/outPath) str`) so companion files ride the
  `/nix/store` closure at absolute, cwd-independent paths. **[C]**
- **Script bodies moved to `ai.claude.hookScripts` / `hookScriptsDir`**
  (BREAKING but latent — no consumer used them); lower to
  `~/.claude/hooks/<name>` (non-executable). **[C]**
- **Event-wiring lowers via ONE shared `hooksToSettings` helper** to BOTH
  backends (HM → `programs.claude-code.settings.hooks`; devenv →
  `files.".claude/settings.json".json.hooks`). The latent devenv `//` mis-feed
  is **GONE** — `claude.code.hooks` records dropped entirely (approach B).
  **[C]**
- **Verified devenv `claude.code.hooks` type** (re-verify on bump, devenv rev
  `5f1cf17b`): `submodule { freeformType = attrsOf hookSubmodule; … }`,
  `hookSubmodule = {enable; name; hookType(enum 17); matcher; command(REQUIRED)}`
  — **command-only** (no http/prompt/agent/mcp_tool, no `timeout`), and the enum
  covers only **17 of the binary's 30** events. That "cannot-ride" tail is WHY
  approach B writes uniform settings.json JSON directly instead of minting
  `claude.code.hooks` records. **[C]** (closeout §3.1/§9e).
- **Composition:** `(pkgs.formats.json {}).type` **CONCATENATES** same-key list
  defs across writers (verified empirically) — so our
  `settings.json.hooks.<Event>` write coexists with devenv's default
  `git-hooks-run` entry with no clobber and no per-event partition. **[C]**
  (closeout §9e).
- Legacy `ai.claude.settings.hooks` kept as a **deprecated composing escape
  hatch**. Drift + type guards: `checks/claude-code-extracted.nix` (blocking
  hook-event enum) + `checks/claude-devenv-hooks-real-type.nix` (real devenv
  module coexistence, NOT a stub). **[C]**

### 3.2 Kiro (`packages/kiro-cli/lib/mkKiro.nix`)

- `ai.kiro.hooks` = `attrsOf (either lines path)` — **raw JSON envelope
  passthrough** to `<configDir>/hooks/<name>.json` (`mkKiro.nix:316-320`).
  Comments (`:275-298`) explicitly mark this **greenfield** and say to model it
  typed like `permissions` (the concrete typed precedent at `:220-266`). **[C]**
- **Live consumer:** `autoMemory.nix` returns
  `hooks."kiro-memory" = builtins.toJSON envelope` — one file, four hooks
  (Stop/SessionStart/UserPromptSubmit/Manual) — proving multi-hook
  single-envelope works, and baking absolute-store-path wrappers into
  `action.command`. Any typed refactor must keep this working. **[C]**
- **Delivery asymmetry (already implemented):** HM writes `home.file` **store
  symlinks**; devenv installs **real files** via `enterShell`
  (`install -m 0644 …`). See
  [§5.5](#55-discovery-workspace-local-and-the-2130-global-change).

### 3.3 Verification precedent

- `checks/validate-at-stop.nix` — hermetic, **stub-tool**, feeds a JSON payload
  on stdin, asserts stdout/exit. The reusable Tier-1 contract-test pattern.
  **[C]**
- `checks/model-staleness-claude.nix` — **advisory** binary-grep drift check
  (`grep -aoE 'firstParty:"claude-[a-z0-9-]+"'` vs committed `models.json`); the
  template for hook-surface drift. `checks/claude-code-extracted.nix` is the
  **blocking** sibling. **[C]**
- All checks union into `checks.<system>` (`flake.nix:216`) and run under
  sandboxed `nix flake check`. **[C]**

---

## 4. Claude Code hook inventory (authoritative)

Source: `code.claude.com/docs/en/hooks` fetched 2026-07-20 (301-redirect from
`docs.claude.com/en/docs/claude-code/hooks`), cross-checked against 30
event-name literals grep'd from the `claude-code-2.1.214` Bun binary and
devenv's independent 17-event `hookType` enum. The docs and binary agree on the
event _set_. **[C]**

### 4.1 Events (33 documented; 30 in binary)

Lifecycle: `SessionStart` · `Setup` · `SessionEnd`. Per-turn: `UserPromptSubmit`
· `UserPromptExpansion` · `Stop` · `StopFailure`. Agentic loop: `PreToolUse` ·
`PermissionRequest` · `PermissionDenied` · `PostToolUse` · `PostToolUseFailure`
· `PostToolBatch` · `SubagentStart` · `SubagentStop` · `TaskCreated` ·
`TaskCompleted`. Async/display: `Notification` · `MessageDisplay` · `CwdChanged`
· `FileChanged` · `ConfigChange` · `InstructionsLoaded` · `WorktreeCreate` ·
`WorktreeRemove` · `TeammateIdle`. Context: `PreCompact` · `PostCompact`. MCP:
`Elicitation` · `ElicitationResult`.

The **classic load-bearing 9** (stable across versions, and what most tooling
targets):
`PreToolUse, PostToolUse, UserPromptSubmit, Notification, Stop, SubagentStop, PreCompact, SessionStart, SessionEnd`.
The other ~24 are newer/niche and version-gated.

### 4.2 Input (stdin) contract

Common to all:
`session_id, transcript_path, cwd, permission_mode, hook_event_name`, plus
`prompt_id` (v2.1.196+, **absent until first user input**), `effort` (`{level}`,
tool-context events only), and — **only in subagent context** — `agent_id`
(present _only_ inside a subagent), `agent_type`. `permission_mode` ∈
`{default,plan,acceptEdits,auto,dontAsk,bypassPermissions}`; **the "Manual" mode
arrives as `"default"`, never `"manual"`.** `transcript_path` is written async
and may lag the current turn → Stop hooks read `last_assistant_message` instead.
Notable per-event additions: `PreToolUse/PostToolUse` add `tool_name`,
`tool_input`, `tool_use_id` (+`tool_response`, `duration_ms` on Post);
`UserPromptSubmit` adds `prompt` (**non-empty**, unlike Kiro);
`Stop/SubagentStop` add `last_assistant_message` (+`background_tasks`,
`session_crons` v2.1.145+); `SessionStart` adds `source`
(`startup|resume|clear|compact`) and optional
`model`/`agent_type`/`session_title`. **[C]** (primary: docs L605-644 + each
event §; citation store: `typed-hooks-research/primary-source-hardening.md` §1).

### 4.3 Output contract (this is what memory/turn-min need)

- **Exit codes:** `0` success (**JSON parsed only on exit 0**; stdout added to
  Claude's _context_ only for
  `UserPromptSubmit`/`UserPromptExpansion`/`SessionStart`, else → debug log);
  `2` blocking error (stderr → model, per-event effect table — PoC: PreToolUse
  blocks tool, UserPromptSubmit blocks+**erases** prompt, Stop continues convo,
  **PostToolUse+SessionStart cannot block**); other = non-blocking
  (`<hook> hook error` notice + first stderr line). **Exit 1 does _not_ block**
  (a common trap; only exit 2 does, except `WorktreeCreate`). **[C]** (docs
  L8-76; anthropics reference impl).
- **Timeout defaults:** `command`/`http`/`mcp_tool` = **600 s** (not 60);
  `prompt` = 30 s; `agent` = 60 s. `UserPromptSubmit` lowers
  command/http/mcp_tool → 30 s; `MessageDisplay` → 10 s; `SessionEnd` → 1.5 s.
  On timeout the hook is canceled, output discarded, action **proceeds
  (fail-open)**. **[C]** (docs L328 — **corrects an earlier "60 s"
  assumption**).
- **Universal JSON stdout:** `continue` (default `true`; overrides
  event-specific decisions), `stopReason`, `suppressOutput`, `systemMessage`,
  `terminalSequence` (v2.1.141+). All output strings capped at **10 000 chars**
  (overflow spilled to a file+preview).
- **Blocking / control** (via top-level `decision:"block"`+`reason`, or nested
  `hookSpecificOutput`): `PreToolUse` blocks/rewrites via
  `hookSpecificOutput.permissionDecision ∈ {allow,deny,ask,defer}` +
  `updatedInput` (**not** a top-level `decision:block` — **[R]** corrected by
  verifier); `PostToolUse` via `decision:"block"` + `updatedToolOutput` +
  `additionalContext`; `Stop/SubagentStop` via `decision:"block"` +
  `additionalContext`; `SessionStart` via `additionalContext` +
  `initialUserMessage` + `reloadSkills` + `watchPaths`; `UserPromptSubmit` via
  `decision:"block"`. Many events (`Notification`, `SessionEnd`,
  `PostToolUse*`-already-ran, …) cannot block. **[C]**

### 4.4 Matchers, config hierarchy, scoping

- **Matcher** = per-event string with a precise 3-way evaluation:
  `*`/`""`/omitted → **match all**; charset **only** `[A-Za-z0-9_ \-,|]` →
  **exact string / `|`-or-`,`-separated exact list**; **any other char →
  JavaScript _unanchored_ regex** (`RegExp.test`; anchor with `^…$`). Matched
  against tool name (`PreToolUse`/`PostToolUse`), `source` (`SessionStart`),
  agent type (`SubagentStart/Stop`), notification/config/error type, etc.
  `v2.1.191+` allows `,`; `v2.1.195+` treats hyphens as exact-match (older:
  regex). **In the PoC set, `Stop` and `UserPromptSubmit` take _no_ matcher — a
  `matcher` field is silently ignored** (also PostToolBatch, TeammateIdle,
  Task*, Worktree*, MessageDisplay, CwdChanged). A per-handler **`if`** field
  (permission-rule syntax, e.g. `Bash(git *)`) filters on tool name+args.
  **[C]** (docs L189-260; hardening §6).
- **Sources & precedence:** `~/.claude/settings.json` (user) →
  `.claude/settings.json` (project) → `.claude/settings.local.json` (local) →
  **plugin `hooks/hooks.json`** → **skill/agent frontmatter `hooks:`** →
  managed/enterprise. **Hooks MERGE (union) across all sources**, unlike scalar
  settings which override. Enterprise `allowManagedHooksOnly` can suppress the
  rest. **[C]**
- **Scoping:** plugin-shipped _agents_ **cannot** embed hooks (security);
  locally-authored **skill/agent frontmatter CAN** embed `hooks:` (scoped to the
  component's lifetime, and for subagents a `Stop` hook auto-converts to
  `SubagentStop`). **[C]**
- **Subagents:** agentic-loop hooks **fire inside subagent execution** (stdin
  gets `agent_id`, present _only_ inside a subagent);
  `SubagentStart`/`SubagentStop` bracket delegations. **[C]** for the docs
  contract — but the two primary sources only **bracket** the actual firing:
  issue **#34692** reported per-tool subagent hooks _not_ firing, but on
  **v2.1.76** (5+ minors before our pinned 2.1.214) and was **auto-closed
  `not_planned` by stale-bot (2026-05-30)**, not fixed by a maintainer; the
  current docs now document the exact `agent_id` field that issue requested. So
  the docs assert firing while the sole (stale) repro denies it → **still `[U]`;
  verify per-tool subagent firing on the pinned binary before typing
  subagent-tool governance.** **[U]** (hardening §9).

### 4.5 Composition (Claude)

All matching hooks for an event **run in parallel**; identical handlers (same
command+args, or same HTTP URL) are **de-duplicated**; blocking aggregates
**most-restrictive-wins** (any `exit 2`/`deny` blocks; `deny>ask>allow`), and
every sibling still runs. **⇒ Nix does not concatenate scripts — it emits one
array entry per contributor and the CLI unions them.** **[C]** (`section_02`).

---

## 5. Kiro CLI hook inventory (v3 primary; v2 stub)

### 5.1 The trigger set is contested — read this first

Three primary sources give three different answers, at three different dates:

| Source (date)                                     | Triggers                                                                                                                            | Notes                                                                                                                                                                               |
| ------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `kiro.dev/docs/cli/hooks/` (Jun 5 2026)           | **5**: `AgentSpawn`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`                                                        | rich per-trigger stdin; `Stop.assistant_response`, `UserPromptSubmit.prompt` documented **non-empty**; Stop can return `{"decision":"block"}`                                       |
| `kiro.dev/docs/cli/v3/hooks/` (Jun 17 2026)       | **11**: `SessionStart`, `Stop`, `Pre/PostToolUse`, `Pre/PostTaskExec`, `UserPromptSubmit`, `PostFile{Create,Save,Delete}`, `Manual` | says **`AgentSpawn`→`SessionStart`** in the 2.x→3.0 conversion table                                                                                                                |
| **`kiro-cli-2.13.0` binary** (grep, this session) | **~6 present**: `SessionStart`(76), `Stop`(560), `PreToolUse`(9), `PostToolUse`(8), `UserPromptSubmit`(1), `Manual`(45)             | `PreTaskExec`/`PostTaskExec`/`PostFileCreate`/`PostFileSave`/`PostFileDelete` = **0**; `agentSpawn`(camelCase, 5) is the `ChatTriggerType` **telemetry** enum, not the hook trigger |

**Reconciliation (my reading, [U] until a live TUI run settles it):** the **v3
page (newer, Jun 17)** is authoritative for _intended_ v3 triggers, but the
**2.13.0 binary lags the docs** — the 5 Task/File triggers have no string
presence, so they are **documented-ahead-of-implemented (or IDE-only leakage)**
at the pinned version. The **actually-usable v3 triggers at 2.13.0** are
`SessionStart, Stop, PreToolUse, PostToolUse, UserPromptSubmit, Manual` — of
which `SessionStart` and `Manual` are **present-and-working (autoMemory proves
it) but undocumented on the June-5 page.** The `mkKiro.nix:295-298` comment's
11-trigger PascalCase list matches the v3 doc page, i.e. it inherits the same
docs-ahead drift.

> This is the motivating case for
> [§10 drift detection](#10-drift-detection--provenance): no single source is
> trustworthy; only _binary-grep ∩ docs-diff_ reveals the real surface.

### 5.2 Envelope schema

`<configDir>/hooks/<name>.json` =
`{ version:"v1", hooks:[ { name, description?, trigger, matcher?, action:{ type:"command"|"agent", command|prompt }, timeout?(60, 0 disables, ignored for agent actions), enabled?(true) } ] }`.
**One file holds many hooks across many triggers** (autoMemory ships 4). **[C]**

### 5.3 Input / output / blocking

- **stdin is metadata-only in practice** (`{session_id, cwd, hook_event_name}`);
  the documented `UserPromptSubmit.prompt` / `Stop.assistant_response` arrive
  **empty** on tested 2.11/2.12 (in-repo D12/D23). **This is itself a
  doc-vs-binary drift to re-verify on 2.13.0** — the June-5 docs now _claim_
  those fields are populated. **[U]**
- **Blocking:** exit `2` blocks (`PreToolUse`/`UserPromptSubmit`), stderr→LLM;
  stdout added to context on exit 0 (`SessionStart`/`UserPromptSubmit`); other
  exits = warning, proceed. **Additionally, `Stop` can return
  `{"decision":"block","reason":...}` on stdout** — so the earlier "Kiro has no
  JSON decision channel" claim is **[R] refuted**; Kiro `Stop` _can_ block via
  JSON. **[C]** (my docs fetch + verifier).
- **`action.type:"agent"`** appends a prompt to the current model context (no
  subprocess, ignores timeout) — inline steering, **not** a subagent dispatch.
  **[C]**

### 5.4 Lifecycle asymmetries

`Stop` fires **per-turn**, not at session end; there is **no `SessionEnd`**.
Memory/telemetry must debounce and self-flush (autoMemory's OR-gate +
tail-flush). **[C]**

### 5.5 Discovery: workspace-local, and the 2.13.0 global change

- Pre-2.13.0 (what in-repo memory records): v3 loads hooks **only** from
  workspace `.kiro/hooks/`, **not** global `~/.kiro/hooks/`; devenv installs
  real files, HM symlink delivery is dead. **[C]** for the location rule (issues
  **#9075** closed-dup, **#7737** closed-dup, **#5440** OPEN). **Cause is
  LOCATION, not symlink-skip:** #9075 shows the scan looks for
  `<folder>/.kiro/hooks/`, and since `~/.kiro` _is_ the `.kiro` dir the
  effective path is `~/.kiro/.kiro/hooks/` — so a **real** file at
  `~/.kiro/hooks/` is _also_ undiscovered (Skills+Steering load globally, hooks
  didn't). The "`read_dir` skips store symlinks" claim is thus **[R]** as the
  reason for the _global_ miss (it never isolated a workspace-local symlink); it
  survives only as an untested hypothesis about symlink-follow.
- **2.13.0 (Jul 17 2026) changelog:** _"Hooks placed in `~/.kiro/hooks/` now
  fire in every workspace… Workspace-level hooks continue to work alongside
  global ones. Available in V3 (`kiro-cli --v3`)."_ So **CLI global discovery
  now exists** — the autoMemory **invariant #11 ("global ignored") is now
  stale** and the `claude-rules-kiro-cli.md` fragment needs a note. **[C]**
  **But "global hooks" is CLI-v3-only:** the IDE tracker **#5440 is still OPEN**
  (48 👍, `pending-maintainer-response`/`keep-open`, updated **2026-07-16** —
  the day before the CLI changelog). Don't generalize the CLI change to the IDE.
  **[C]** (hardening §9).
- **Open, load-bearing:** does 2.13.0's global scan **follow store symlinks**?
  If yes, HM `home.file` → `~/.kiro/hooks/` becomes a viable delivery path (no
  more devenv-only). If it still skips symlinks, HM needs a `home.activation`
  real-file copy. **Needs a live 2.13.0 test.** **[U]**

### 5.6 TUI vs headless

Kiro v3 hooks are effectively **TUI-only** — the legacy non-TUI classic mode
doesn't run the v3 engine, so headless Kiro fires no v3 hooks. (Claude hooks
_do_ fire in headless `-p`.) This constrains live verification: even a "live"
Kiro hook test must drive the TUI. **[C]**

### 5.7 Subagents

Kiro docs state hooks **do not fire in subagents** — issue **#7755** (OPEN)
quotes the vendor docs verbatim: _"Steering files and MCP servers work in
subagents exactly as they do in the main agent. However, subagents do not have
access to Specs, and **Hooks will not trigger in subagents**."_ The request to
change this is unresolved/open. `PreTaskExec`/`PostTaskExec` (where present)
fire only around **spec tasks** (`/spec run`), not arbitrary delegation — so
they're not a general subagent-governance hook. This diverges from Claude (whose
docs _assert_ subagent firing, §4.4) — the "both CLIs fail in subagents" framing
is wrong. **[C]** (hardening §9).

### 5.8 v2 (deferred — stub only)

v2 embedded hooks lived inside agent config; schema diverges from v3
(embedded→standalone files; `timeout_ms` ms/default 30000 → `timeout`
seconds/default 60). `kiro-cli agent migrate` converts. Build **code stubs
only**; do not model v2 typed. **[C]**

---

## 6. Edge cases & gotchas

| #   | Edge case                                                                              | CLI    | Confirmed?                                                                           | Impact on typed design                                                                                                                                                                                  |
| --- | -------------------------------------------------------------------------------------- | ------ | ------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Hooks **don't fire in subagents**                                                      | Kiro   | **[C]** (docs, #7755)                                                                | Subagent telemetry/memory blind spot — document it                                                                                                                                                      |
| 2   | Agentic-loop hooks **do** fire in subagents (`agent_id`)                               | Claude | docs **[C]**; firing **[U]** — #34692 (2.1.76, stale-bot close) vs current docs      | Docs assert firing + now ship the `agent_id` #34692 asked for; sole repro is 5+ minors stale. Re-verify per-tool subagent firing on pinned 2.1.214 before typing subagent-tool hooks                    |
| 3   | v3 hooks **TUI-only** (no headless firing)                                             | Kiro   | **[C]**                                                                              | Live tests must drive TUI; can't smoke headlessly                                                                                                                                                       |
| 4   | Discovery **workspace-local**; **global added in 2.13.0**                              | Kiro   | **[C]**                                                                              | HM delivery decision hinges on symlink-follow ([§5.5])                                                                                                                                                  |
| 5   | `read_dir` **skips store symlinks**                                                    | Kiro   | **[R]** as global-miss cause (#9075=location); **[U]** if 2.13 scan follows symlinks | Global miss = path-shallowness, not symlinks; devenv real-file copy stands. Symlink-follow (Open Q1) still gates HM `home.file`                                                                         |
| 6   | `Stop` **per-turn**, **no SessionEnd**                                                 | Kiro   | **[C]**                                                                              | "once at session end" intent has no Kiro equivalent                                                                                                                                                     |
| 7   | stdin **metadata-only**, empty `prompt`                                                | Kiro   | **[C]** on 2.11/2.12; **[U]** on 2.13                                                | Kiro memory can't query-on-prompt; self-locates transcript                                                                                                                                              |
| 8   | **MCP/hook env replaces process env** → bare commands lose PATH                        | Both   | **[C, R]**                                                                           | All generated hook scripts use **absolute store paths** (repo standard). _Correction:_ mechanism is a **curated-subset** inheritance, not a full strip (`checks/bare-commands.nix` enforces regardless) |
| 9   | `Stop` can **block** → infinite-loop risk, guarded by `stop_hook_active`               | Claude | **[C]**                                                                              | Typed `Stop` must expose/loop-guard (validate-at-stop precedent)                                                                                                                                        |
| 10  | Skill/agent **frontmatter hooks**; plugin agents **can't** embed hooks                 | Claude | **[C]**                                                                              | A future "ship a hook with a skill" path exists on Claude; not on Kiro                                                                                                                                  |
| 11  | Hooks **union across sources & run in parallel**; identical deduped                    | Claude | **[C]**                                                                              | Nix emits array entries; no concat/dispatcher                                                                                                                                                           |
| 12  | Two doc pages + binary give **3 different trigger sets**                               | Kiro   | **[C]**                                                                              | Motivates drift detector; soft-enum + sidecar                                                                                                                                                           |
| 13  | devenv `claude.code.hooks` schema mismatch masked by stub                              | (Nix)  | **[C]**                                                                              | ✅ FIXED (slice C3/C5): writes `settings.json.hooks` directly + real-type guard                                                                                                                         |
| 14  | Claude event set is **binary-version-specific** (33 docs / 30 binary / 17 devenv-enum) | Claude | **[C]**                                                                              | Soft-enum from an extracted sidecar, never hard-code                                                                                                                                                    |

---

## 7. Composition & precedence

- **Claude:** unions all matching hooks across user/project/local/plugin/skill
  sources, runs them in parallel, dedups identical handlers, aggregates blocking
  most-restrictive. Precedence is _Claude's_, not ours — our only job is to not
  **lose** a contributor. **[C]**
- **Kiro:** every `hooks[]` entry in an envelope fires (autoMemory proves 4);
  multiple envelope files all load and union; multi-hook blocking aggregation
  for one trigger is **undocumented** (inferred any-blocks). **[U]**
- **The shebang/script-concat "problem" is a non-problem.** Because both CLIs
  union array entries, you never concatenate two `#!/usr/bin/env bash` scripts.
  A generated **dispatcher wrapper** would only be needed if a CLI allowed _one
  command per event_ — neither does — and it would be strictly worse (loses
  Claude's parallelism). **[C]**
- **What Nix must compose:**
  - Claude event map = **`listOf` per event → module-system list-concat**
    (multiple modules contributing to `PreToolUse` concatenate; this is the
    _opposite_ of the `mergeWithCollisionCheck` used for rules/skills — hooks
    want **append coexistence**, not collision-as-failure). **[C]**
    (`section_07`).
  - Kiro name-keyed records = **`attrsOf` key-union** (route through
    collision-check so two modules declaring the same hook name is a failure).
    Script bodies compose by attrset key-union too — **[R]** a lens's "listOf
    concat" framing was corrected: the _script-file_ surface is `attrsOf lines`.
    **[C]**
- **The devenv `//` clobber — ✅ RESOLVED (Claude slice C3 `924bb9a1`).** The
  old `claude.code.hooks = (settings.hooks) // cfg.hooks` mis-fed devenv's real
  type and is DROPPED. **CORRECTION (verified empirically, closeout §9e):**
  `pkgs.formats.json` does **NOT** replace same-key lists — it **CONCATENATES**
  them. So writing `files.".claude/settings.json".json.hooks` directly (via the
  shared `hooksToSettings`) coexists with devenv's own `git-hooks-run`
  `PostToolUse` entry — both land in the merged array. Fidelity + parity + no
  clobber, no per-event partition. **[C]** **⇒ Kiro reuse:** if Kiro hooks ever
  compose from >1 writer, this same concat model applies.

---

## 8. Nix module architecture (design sketch — not committed)

Full ground-truth analysis in `section_05`; distilled here.

### 8.1 Keep hooks **per-CLI**; no shared `ai.hooks`

Divergent event vocabularies (~30 vs ~6-11, ~5 overlap), divergent stdin (Claude
rich JSON vs Kiro metadata-only), divergent blocking/lifecycle (`Stop` blocks on
Claude, per-turn on Kiro; no Kiro `SessionEnd`). A shared pool would silently
mis-emit "portable-looking" scripts. Matches the repo's existing "Claude-only,
no `ai.hooks` fanout" stance (`mkClaude.nix:261-263`) and
`feedback_content_separation`. **Share the emission _helpers_, not the option
surface.** **[C]**

### 8.2 Typed shapes (explicit `lib.types`, freeform tail as escape hatch)

- **Claude — keyed BY EVENT** (mirrors `settings.json` 1:1):
  `ai.claude.hooks.<Event> = listOf { matcher; hooks = listOf handler }` where
  `handler` is a tagged union over
  `type ∈ {command,http,prompt,agent,mcp_tool}`, with a
  `freeformType = (pkgs.formats.json {}).type` tail for un-modeled events, and
  event names as a **soft enum** (`either (enum knownFromSidecar) str`) sourced
  from an extracted `hook-events.json` (never hard-coded).
- **Kiro — keyed BY NAMED RECORD** (mirrors the envelope):
  `ai.kiro.hooks.<name> = { trigger; matcher?; action{type,command|script|prompt}; timeout?; enabled?; description? }`,
  `trigger` a soft enum from `hook-triggers.json`.
- The two key differently **on purpose** — the on-disk formats differ. The only
  shared substructure (`{trigger, matcher?, command/script}`) lives in a shared
  emission helper.

### 8.3 Lowering (HM↔devenv parity)

|            | Claude HM                                                                 | Claude devenv                                                                                     | Kiro HM                                  | Kiro devenv                |
| ---------- | ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- | ---------------------------------------- | -------------------------- |
| Target     | generate `settings.hooks` JSON → freeform `programs.claude-code.settings` | **write `files.".claude/settings.json".json.hooks` ourselves** (bypass lossy `claude.code.hooks`) | `home.file` (**dead pre-2.13; symlink**) | `enterShell` **real file** |
| Script cmd | absolute `"${mkHookScript …}"`                                            | same                                                                                              | same                                     | same                       |

`mkHookScript` bakes an inline body with the mandatory strict-mode header to an
absolute store path (Claude/Kiro hook env replaces PATH). Generalizes
autoMemory's existing wrappers. **[C]**

### 8.4 Migration is breaking

> **Claude half ✅ DONE (slice C2 `11c3f04c`)** exactly as described below:
> `ai.claude.hooks` repurposed to the event map, script bodies →
> `ai.claude.hookScripts`/`hookScriptsDir`, legacy `settings.hooks` kept as a
> composing escape hatch; nixos-config had no consumer so the rename was latent.
> **The Kiro half below is the remaining work** (this session).

`ai.claude.hooks` (script bodies) wants the same name as the new event map →
repurpose it to the event map, move script bodies to
`ai.claude.hookScripts`/`hooksDir`; keep freeform `settings.hooks` as a
deprecated escape hatch. `ai.kiro.hooks` typed records replace the raw envelope,
but **autoMemory is a live raw consumer** → keep a raw `ai.kiro.hooksJson`
escape hatch so autoMemory keeps working; migrate it incrementally (its
`action.command = either str path` accepts pre-baked wrapper paths). Do it in
the factory sweep, update `nixos-config` in lockstep (HITL per
`feedback_nixos_config_hitl`). **[C]**

---

## 9. Verification strategy (answers "can nix check cover token-burning hooks?")

**Direct answer: no — `nix flake check` is sandboxed/pure (no network, no auth),
so a token-burning "does it actually fire?" test cannot run as a check. Live
firing MUST be a flake app / devenv task / HITL harness.** Everything else is
hermetic. **[C]**

**Three tiers:**

1. **Tier 1 — emission golden tests (hermetic, `nix flake check`).** Prove every
   typed event on both CLIs serializes to the correct `settings.json.hooks` /
   envelope JSON, on **both** HM and devenv (byte-parity), incl.
   matcher-awareness, absolute-store-path, collision behavior. Extend
   `checks/module-eval.nix` (reuse the `kiro-auto-memory-hm-devenv-parity`
   pattern).
2. **Tier 1b — contract tests (hermetic, `nix flake check`).** Feed a
   **documented stdin payload** to the generated hook **script** with **stub
   tools**, assert stdout/exit (`validate-at-stop.nix` pattern). Covers
   `command`-action logic. **Cannot** cover Kiro `action:agent` / Claude
   `prompt`/`agent` handlers (no subprocess — emission-only). Complex hooks
   additionally get language-level unit tests at build time (distiller
   precedent, `checkPhase`, single build = OOM-safe).
3. **Tier 2 — live firing (real CLI, may burn tokens → NOT a check).** A
   **devenv task** `verify:hooks:live` (primary) + `nix run .#verify-hooks-live`
   flake app (secondary), env-gated/opt-in, driving a throwaway **trusted**
   project — exactly the `dev/scripts/kiro-memory-hitl.sh` shape. This is the
   _only_ place that proves a hook actually fires and observes the _real_ stdin.
   **Reject** an env-gated no-op check (`HOOKS_LIVE_TOKEN`) — the sandbox strips
   auth before the gated branch runs, giving false assurance. **[C]**

**Capture→replay bridge (recommended):** the Tier-2 probe dumps each event's
**real stdin** to committed fixtures, which then seed the Tier-1b contract
tests. This is what actually **detects CLI stdin-schema drift on upgrade** (and
would have caught the Kiro empty-`prompt` drift). **[C]**

**Per-hook verification matrix** (abbrev.; rows = event, cols = _T1 emission?_ /
_T1b contract?_ / _T2 live-needed?_): all events → **T1 yes**; `command`-action
events → **T1b yes**; firing/agent-injection/real-stdin → **T2 yes**. Kiro
TUI-only events are **T2-only** for firing proof.

---

## 10. Drift detection & provenance

The Kiro 5-vs-11-vs-binary conflict ([§5.1]) and the Claude 33/30/17 spread
([§4.1]) prove the surface drifts and no single source is authoritative. Design
(adapts `model-staleness-claude.nix`):

- **Binary-grep drift check (hermetic, advisory, in `nix flake check`).** Grep
  each binary's event/trigger vocabulary with a stable anchor (Claude:
  `grep -aoE '"PreToolUse"(,"[A-Za-z]+")+'`; Kiro: PascalCase trigger literals —
  **anchor the right enum**, the `ChatTriggerType` camelCase telemetry set is a
  red herring that a research agent fell into this session). Diff vs a committed
  sidecar; new/unknown tokens **warn** (nudge a curation PR), never fail.
  **[C]**
- **Blocking guard (folds into `mkClaudeExtract`/new `mkKiroHooksExtract`).** A
  typed event we removed/renamed is a **correctness bug** (we'd emit config the
  CLI ignores) → `exit 1`, like `settingsBooleanKeys` already does. Split
  advisory-for-additions / blocking-for-removals, mirroring the existing
  `model-staleness` (advisory) + `claude-code-extracted` (blocking) pair.
  **[C]**
- **Docs-diff (impure → flake app / devenv task / scheduled Action, NOT a
  check).** Fetch → normalize (strip nav) → committed snapshot + SHA256 → diff
  on demand. Weekly cron + `workflow_dispatch`, opens an advisory PR/issue.
  **`nix flake check` cannot** do this (network). **[C]** — and it must snapshot
  **both** Kiro doc pages, since they disagree.
- **Committed sidecars = the SSOT _and_ the provenance store:**
  `packages/claude-code/hook-events.json`,
  `packages/kiro-cli/hook-triggers.json` (new `packages/kiro-cli/` dir), each
  recording per-CLI@version: `typedEvents` (curated subset we expose),
  `binaryVocabulary` (diff target), `schemaFieldMarkers` (presence guard), and
  `provenance{binaryVersion, docsUrl(s), docsSnapshotSha256, lastVerifiedVersion, lastVerifiedDate, per-event source∈{docs+binary,binary-only,docs-only}}`.
  **[C]**
- **Re-fingerprint on version bump:** `claude-code.nix` already has an
  `extraExtract` that regenerates a committed sidecar in the same update PR —
  add the hook-surface regen there; add an `extraExtract` to `kiro-cli.nix` (has
  none today). So a bump can't silently drift the enum, and the provenance stamp
  refreshes automatically. **[C]**
- **Provenance per option (DRY):** typed option modules read the sidecar and
  auto-suffix each option's `description` with
  `(verified vs <cli> <ver> + <docsUrl>, last-verified <date>)`; an advisory
  check flags when `lastVerifiedVersion` ≠ the pinned `sources.json.version`.
  This is the machine-checkable "where did this come from" you asked for.
  **[C]**

---

## 11. Per-hook documentation contract (the post-PoC deliverable)

For **every** typed event, fill and test this template (input/output/failure at
each hook):

```
event / trigger:        <name> (<cli> <min-version>)
fires when:             <...>
matcher:                <none | matches X>  (regex? glob? version-gated?)
stdin schema:           <fields>            (CONFIRMED source: docs URL / captured fixture)
stdout/exit contract:   <exit 0/2/other; JSON fields honored>
can block?:             <yes/no + mechanism>     inject context?: <field>
failure handling:       timeout=<s> → <behavior>; nonzero exit → <behavior>;
                        malformed JSON → <behavior>
verification tier:      T1 emission ✓ | T1b contract <✓/n-a> | T2 live <needed?>
provenance:             last-verified <cli ver> / <docs snapshot date>
```

_Example (Claude `PreToolUse`):_ fires before a tool call; matcher = tool name;
stdin `{…, tool_name, tool_input, agent_id?}`; blocks via
`permissionDecision:"deny"`, rewrites via `updatedInput`; timeout 600s default →
non-block on timeout; T1✓/T1b✓/T2 for real-stdin capture. _Example (Kiro
`Stop`):_ fires per-turn; no matcher; stdin metadata-only (`assistant_response`
[U] on 2.13); blocks via `{"decision":"block"}` or exit 2; T1✓/T1b✓/T2 (TUI-only
firing).

### 11.1 Filled contracts — PoC set (2026-07-20b)

Every **Claude** field below is **CONFIRMED-source** against the hashed
`code.claude.com/docs/en/hooks.md` snapshot (§18 /
`primary-source-hardening.md`) unless flagged `⟨probe⟩`. Every **Kiro** stdin
field is `⟨probe⟩` (metadata-only confirmed on 2.11/2.12; the documented payload
fields arrive empty — re-capture on 2.13.0). `⟨probe:Qn⟩` ties a field to a §12
live-probe question.

**Claude — `PreToolUse` (v2.0, all handler types)**

```
fires when:   after tool params built, before the call runs. Only on real tool calls
              (@-referenced files bypass it — use a Read deny rule instead).
matcher:      tool name — 3-way eval (exact-list | JS-regex); +per-handler `if` (Bash(git *)). CONFIRMED
stdin:        common{session_id, prompt_id?, transcript_path, cwd, permission_mode, effort?,
              hook_event_name, agent_id? ⟨probe:Q3⟩, agent_type?} + tool_name, tool_input(tool-shaped),
              tool_use_id.  CONFIRMED (docs L1359+)
stdout/exit:  exit0→JSON parsed (stdout NOT added to context); exit2→blocks call, stderr→Claude;
              other→non-block "hook error" notice.  CONFIRMED
can block?:   YES — hookSpecificOutput.permissionDecision∈{allow,deny,ask,defer}+permissionDecisionReason,
              or exit2.   inject?: hookSpecificOutput.additionalContext.  rewrite?: updatedInput.  CONFIRMED
failure:      timeout 600s→cancel, tool PROCEEDS (fail-open; Agent-SDK callback fails-closed, v2.1.210);
              exit≠0,2→non-block notice; malformed JSON on exit0→"JSON validation failed", ignored, proceeds.
verify tier:  T1 emission ✓ | T1b contract ✓ | T2 live: real-stdin capture + subagent-firing (Q3)
provenance:   docs snapshot 2026-07-20 sha 509b80… ; anthropics examples/hooks/bash_command_validator (ref 015170d3)
```

**Claude — `PostToolUse` (v2.0, all handler types)**

```
fires when:   immediately after a tool completes successfully.  CONFIRMED
matcher:      tool name (same values as PreToolUse).  CONFIRMED
stdin:        common + tool_name, tool_input, tool_response(tool-shaped), tool_use_id, duration_ms?.  CONFIRMED
stdout/exit:  exit0→JSON parsed (stdout→debug log, NOT context); exit2→CANNOT block (tool already ran),
              stderr→Claude.  CONFIRMED
can block?:   NO (post-hoc).  inject?: additionalContext.  rewrite?: updatedToolOutput (must match tool
              output shape) / updatedMCPToolOutput (MCP-only); decision:"block"+reason adds a note but
              Claude still sees the original output.  CONFIRMED (docs L1710+)
failure:      timeout 600s→cancel, proceeds; exit≠0,2→non-block; malformed JSON→ignored.
verify tier:  T1 ✓ | T1b ✓ | T2 live: real tool_response capture (Bash/Edit/Write shapes)
provenance:   docs snapshot 2026-07-20 §PostToolUse
```

**Claude — `UserPromptSubmit` (v2.0)**

```
fires when:   user submits a prompt, before Claude processes it.  CONFIRMED
matcher:      NONE — always fires; a `matcher` field is silently ignored.  CONFIRMED
stdin:        common + prompt (submitted text; NON-EMPTY, unlike Kiro).  CONFIRMED
stdout/exit:  exit0→plain stdout OR JSON.additionalContext added as context; exit2→blocks + ERASES prompt,
              stderr→Claude.  CONFIRMED
can block?:   YES — decision:"block"(+reason, erases prompt) or exit2.  inject?: additionalContext /
              plain stdout; also sessionTitle, suppressOriginalPrompt. CANNOT replace the prompt.  CONFIRMED
failure:      timeout **30s** (lowered from 600)→cancel, output DISCARDED, prompt proceeds w/o context
              (notice v2.1.196); Agent-SDK callback timeout BLOCKS (fail-closed, v2.1.208); exit≠0,2→
              non-block; malformed JSON→ignored, prompt proceeds.
verify tier:  T1 ✓ | T1b ✓ | T2 live: injected context reaches the model
provenance:   docs snapshot 2026-07-20 §UserPromptSubmit (L1117+)
```

**Claude — `Stop` (v2.0) — the validate-at-stop reference event**

```
fires when:   main agent finished responding. NOT on user interrupt (→ none) / API error (→ StopFailure). CONFIRMED
matcher:      NONE — always fires.  CONFIRMED
stdin:        common + stop_hook_active(bool), last_assistant_message, background_tasks[], session_crons[]
              (v2.1.145+).  CONFIRMED
stdout/exit:  exit0→JSON parsed; exit2→prevents stop, continues convo, stderr→Claude.  CONFIRMED
can block?:   YES — decision:"block"+reason (prevents stopping) or exit2.  inject?: hookSpecificOutput.
              additionalContext = non-error feedback ("Stop hook feedback"), same loop protections.  CONFIRMED
loop guard:   stop_hook_active=true while already continuing; Claude force-ends after 8 consecutive blocks.
              (repo lib/validate-at-stop.sh is a faithful instance.)  CONFIRMED
failure:      timeout 600s→cancel, stop ALLOWED; exit≠0,2→non-block; malformed JSON→ignored.
verify tier:  T1 ✓ | T1b ✓ (already exercised by checks/validate-at-stop.nix) | T2 live: real last_assistant_message
provenance:   docs snapshot 2026-07-20 §Stop (L2144+)
```

**Claude — `SessionStart` (v2.0; `command` + `mcp_tool` handlers only)**

```
fires when:   new session / resume / clear / compact (matcher = the reason).  CONFIRMED
matcher:      source ∈ {startup, resume, clear, compact}.  CONFIRMED
stdin:        common + source, model? (ONLY event to receive model; not guaranteed), agent_type?, session_title?. CONFIRMED
stdout/exit:  exit0→plain stdout OR JSON added as context; exit2→CANNOT block (stderr→user only, transcript
              notice v2.1.199).  CONFIRMED
can block?:   NO.  inject?: hookSpecificOutput.{additionalContext, initialUserMessage (seeds -p headless
              first turn), sessionTitle (startup/resume only), watchPaths[], reloadSkills(bool)}.  CONFIRMED
special:      CLAUDE_ENV_FILE persists env to later Bash; re-runs on resume with source="resume".
failure:      timeout 600s→cancel, session proceeds; exit≠0→non-block notice; malformed JSON→ignored.
verify tier:  T1 ✓ | T1b ✓ | T2 live: context reaches model + reloadSkills same-session pickup
provenance:   docs snapshot 2026-07-20 §SessionStart (L913+)
```

**Kiro — `SessionStart` (v3; present+working, undocumented on the Jun-5 page)**

```
fires when:   session start. autoMemory uses it to flush prior sessions' dropped tails.  CONFIRMED (autoMemory + v3 docs)
matcher:      none used.
stdin:        metadata-only {session_id, cwd, hook_event_name}.  ⟨probe:Q4⟩ (2.11/2.12; re-capture on 2.13)
stdout/exit:  exit0 stdout→context; not a block point.  CONFIRMED (v3 exit-code table)
can block?:   no.  inject?: stdout→context.
discovery:    workspace .kiro/hooks/ + global ~/.kiro/hooks/ (2.13 CLI-v3, changelog).  ⟨probe:Q1 symlink-follow⟩
failure:      timeout 60s default (0 disables; ignored for action:agent); nonzero→warning, proceed.
verify tier:  T1 emission ✓ | T1b command-wrapper ✓ | T2 live: TUI-only firing (Q2 trigger set)
provenance:   kiro.dev/docs/cli/v3/hooks (Jun-17); autoMemory.nix; kiro-cli 2.13.0 binary grep
```

**Kiro — `Stop` (v3; per-turn, NOT session-end)**

```
fires when:   end of EACH TURN (v3 page mislabels it "Session ends"); there is no SessionEnd.  CONFIRMED
matcher:      none.
stdin:        metadata-only; documented `assistant_response` arrives EMPTY on 2.11/2.12.  ⟨probe:Q4⟩
stdout/exit:  exit0; CAN return {"decision":"block","reason":…} on stdout (reason→new user message,
              continues) OR exit2.  CONFIRMED (base-docs Stop JSON channel; verdicts [R] fix)
can block?:   YES (JSON decision:block or exit2).
failure:      timeout 60s; NO SessionEnd → memory/telemetry must debounce + tail-flush (autoMemory OR-gate).
verify tier:  T1 ✓ | T1b ✓ | T2 live: per-turn firing + real assistant_response (Q4)
provenance:   kiro.dev/docs/cli/hooks + v3/hooks; autoMemory D11/D24
```

**Kiro — `PreToolUse` (v3)**

```
fires when:   before a tool call.  CONFIRMED
matcher:      optional (tool name).
stdin:        metadata-only.  ⟨probe:Q4⟩ (tool_name/tool_input population unverified)
stdout/exit:  exit2 blocks, stderr→LLM; exit0 proceeds.  CONFIRMED (v3 exit-code table)
can block?:   YES (exit2).  inject?: — (stdout not context-added for this trigger).
failure:      timeout 60s (0 disables).
verify tier:  T1 ✓ | T1b ✓ | T2 live: firing + tool_input payload (Q4)
provenance:   kiro.dev/docs/cli/v3/hooks; 2.13.0 binary (PreToolUse present)
```

**Kiro — `PostToolUse` (v3)**

```
fires when:   after a tool call.  CONFIRMED
matcher:      optional (tool name).
stdin:        metadata-only; documented tool_response population unverified.  ⟨probe:Q4⟩
stdout/exit:  exit0 proceeds; no documented block (post-hoc).  CONFIRMED
can block?:   no (inferred).  inject?: — (undocumented).
failure:      timeout 60s.
verify tier:  T1 ✓ | T1b ✓ | T2 live: firing + tool_response payload (Q4)
provenance:   kiro.dev/docs/cli/v3/hooks; 2.13.0 binary (PostToolUse present)
```

**Kiro — `UserPromptSubmit` (v3)**

```
fires when:   per prompt.  CONFIRMED
matcher:      none.
stdin:        metadata-only; documented `prompt` field arrives EMPTY on 2.11/2.12.  ⟨probe:Q4⟩
stdout/exit:  exit0 stdout→context; exit2 blocks (rejects prompt), stderr→LLM.  CONFIRMED (v3 exit-code table)
can block?:   YES (exit2).  inject?: stdout→context.
failure:      timeout 60s.
verify tier:  T1 ✓ | T1b ✓ | T2 live: firing + real prompt population (Q4)
provenance:   kiro.dev/docs/cli/v3/hooks; autoMemory D12
```

**Kiro — `Manual` (v3; on-demand)**

```
fires when:   user-triggered on demand (autoMemory uses it for force-distill /remember).  CONFIRMED (autoMemory)
matcher:      none.
stdin:        metadata-only.  ⟨probe:Q4⟩
stdout/exit:  exit0 proceeds; not a block point.  CONFIRMED
can block?:   no.  inject?: — .
note:         present+working but undocumented on the Jun-5 page (only on the v3 page).
verify tier:  T1 ✓ | T1b ✓ | T2 live: manual /hooks invoke fires it (Q2)
provenance:   kiro.dev/docs/cli/v3/hooks; autoMemory.nix (Manual entry); 2.13.0 binary (Manual present)
```

---

## 12. Consolidated open questions (load-bearing first)

1. **[LB]** Kiro 2.13.0: does the new global `~/.kiro/hooks/` scan **follow
   store symlinks**? → decides whether HM can deliver Kiro hooks at all.
   _Settle: live 2.13.0 test._
2. **[LB]** Which Kiro triggers does **2.13.0 actually implement** (5 / 6 / 11)?
   Binary shows ~6; v3 docs say 11. _Settle: TUI fixture firing each trigger +
   deeper binary inspection._
3. **[LB]** Does the pinned **Claude 2.1.214** fire per-tool hooks **in
   subagents**? Primary sources _bracket_ it: current docs say yes (and now ship
   the `agent_id` field #34692 requested); the sole repro #34692 says no but on
   **2.1.76** and was **stale-bot-closed `not_planned`**, not fixed. → gates
   typing subagent-tool governance. _Settle: run a Bash/Edit inside an `Agent`
   call on 2.1.214, check the PreToolUse/PostToolUse hook fires and stdin
   carries `agent_id`._
4. **[LB]** Is Kiro stdin still **metadata-only** on 2.13 (docs now claim
   `prompt`/ `assistant_response` populated)? → gates Kiro memory/telemetry
   payload usefulness.
5. What exact type does devenv's `claude.code.hooks` expect, and is `//`-merge
   malformed or merely lossy today? (Confirms the [§7] latent-bug fix.)
6. Kiro multi-hook blocking aggregation (first-exit-2 vs any-exit-2) —
   undocumented.
7. Handler-type scope for Claude v1: `command` only, or all 5?
8. Fold autoMemory into typed `ai.kiro.hooks` now, or keep raw + migrate later?

---

## 13. Decisions needed from you

Batched; my recommendation first. (Several were surfaced independently by
multiple research lenses — consensus noted.)

| #   | Decision                     | Options                                                     | Recommendation                                                                                                                     |
| --- | ---------------------------- | ----------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| D1  | Shared `ai.hooks` vs per-CLI | shared / **per-CLI** / hybrid                               | **Per-CLI** (unanimous across lenses; divergent schemas)                                                                           |
| D2  | Claude event scope for PoC   | PoC subset / classic-9 / all-33                             | **PoC subset now** (`Stop, PostToolUse, UserPromptSubmit, SessionStart, PreToolUse`) → classic-9 full → exotic tail stays freeform |
| D3  | Kiro scope                   | full-11 now / **implemented-set now** / defer               | **Type the 2.13-implemented set now** (bounded), soft-enum the rest                                                                |
| D4  | Keep freeform passthrough?   | **yes** / typed-only                                        | **Yes** — escape hatch for new/undocumented events (mirrors `settings`)                                                            |
| D5  | Canonical Claude schema      | adopt devenv `claude.code.hooks` / **own richer schema**    | **Own richer schema** — devenv's is command-only, no output/inject contract, no Kiro                                               |
| D6  | Kiro HM delivery             | activation real-file copy / **devenv-only** / both          | **Devenv-only** until D-open-Q1 resolves; then reconsider global HM                                                                |
| D7  | Live-test home               | **devenv task + flake app** / task-only / app-only          | **devenv task primary + flake app secondary**, env-gated                                                                           |
| D8  | Migration style              | union-type / **repurpose + escape hatch** / parallel option | **Repurpose `ai.claude.hooks`→event map; `hookScripts` for bodies; raw `ai.kiro.hooksJson` hatch**                                 |
| D9  | Fold autoMemory              | now / **keep byte-identical, migrate later**                | **Generalize builder, keep autoMemory output byte-identical during PoC** (its parity tests lock it)                                |
| D10 | Drift check severity         | all-advisory / all-blocking / **split**                     | **Split**: advisory for new tokens, blocking for removal/rename of a typed event                                                   |

---

## 14. Recommended phasing

- **Phase 0 (now):** this assessment + resolve the 4 load-bearing open questions
  via a small live 2.13.0 / pinned-Claude probe (Tier-2 harness, one-time; also
  seeds fixtures).
- **Phase 1 (PoC):** type the D2/D3 PoC subset per CLI; emission golden tests
  (T1) + contract tests (T1b); fix the devenv `//` latent bug; commit the
  `hook-{events,triggers}.json` sidecars + advisory binary-grep drift check.
- **Phase 2 (core):** classic-9 Claude + implemented Kiro set;
  output/inject/decision envelope typed; the three future-plan builders
  (telemetry, memory-generalized, turn-min) wired on top; docs-diff app + cron.
- **Phase 3 (hardening / post-PoC):** fill the [§11] per-hook documentation
  contract for every typed event with captured-fixture provenance and
  failure-handling tests; migrate autoMemory onto the typed surface; blocking
  drift guard.

### Backlog — concrete follow-ups (do it right, not surgical)

> **Operator framing (2026-07-20f):** the north star is a **complete, correct
> typed hook option surface across BOTH ecosystems** — the foundation for wiring
> in **different memory systems** (to eval/compare) and **telemetry** (to
> measure hook effectiveness). Options get designed RIGHT on their own merits;
> **implementations map onto the options, never the reverse.** (`B1` — the
> `extraExtract` sidecar auto-refresh — is already DONE via the
> `*-extracted.json` approach on both CLIs, so it drops off this list.)

- **B2 — retire the surgical `hooksJson` bridge; migrate consumers onto the
  typed surface.** `ai.kiro.hooksJson` was shaped to accept the existing
  autoMemory _pilot_'s pre-baked envelope verbatim (D9 "byte-identical"). The
  pilot is **not** the destination — de-emphasize the byte-identical constraint
  and do NOT let the pilot shape the option surface. Once the done-right typed
  surface is complete: migrate autoMemory (and any memory impl) onto typed
  `ai.kiro.hooks` records; **remove anything shaped to the pilot**
  (pilot-matching `hooksJson` usage + test shapes); accept that the pilot's
  on-disk output may change (e.g. per-record files vs. today's single envelope).
  Design the typed surface to EXPRESS what consumers need so impls map cleanly —
  e.g. an optional **envelope/group key** to co-locate records in one Kiro file,
  a **telemetry hook-fire** channel, parity across the FULL hook set (not just
  the PoC subset). Whether `hooksJson` survives at all (as a genuinely _generic_
  escape hatch) or is dropped is part of this. This session: nothing to undo —
  the bridge stays so autoMemory keeps working; B2 is the follow-up.

- **B3 — investigate wiring the non-hermetic extraction into automation; assess
  the auth cost.** The binary-grep extraction is hermetic + wired
  (`passthru.extracted` + blocking drift check). The OTHER extraction paths are
  not: (a) **docs-diff contract extraction** (fetch the hook docs, diff for
  stdin/stdout _contract_ drift — public URLs, no auth, but network → scheduled
  Action / flake app, not a `nix flake check`); (b) **live Tier-2 capture**
  (fire hooks on the _authenticated_ CLI, capture real stdin — needs an authed
  CLI + burns tokens → cannot be a sandboxed check). Investigate whether/where
  each can be wired (scheduled Action, devenv task, HITL harness), **understand
  exactly what needs auth** and what that constrains, and make a deliberate
  choice (token-secret CI vs. stays-HITL) rather than defaulting.

---

## 15. Verification-pass corrections applied (transparency)

The research fan-out's load-bearing claims were adversarially verified (36
CONFIRMED, 16 REFUTED, 4 UNCERTAIN). Corrections already folded into this doc:
upstream `programs.claude-code.hooks` is **typed** (not freeform);
`ai.claude.hooks` writes **non-executable** files; Claude `PreToolUse` blocks
via `permissionDecision:"deny"` (not top-level `decision`); **Kiro `Stop` _can_
block via JSON** (not exit-only); **Claude fires hooks in subagents, Kiro does
not** (the "both fail" claim was wrong); the MCP-env issue is a
**curated-subset** inheritance, not a full PATH strip; hooks compose via
`attrsOf`/`listOf` merge, not script concatenation; **2.13.0 added global Kiro
hooks** (repo memory stale). Claims still **[U]**: the symlink-skip mechanism,
exact 2.13 trigger implementation, subagent-tool firing on the pinned Claude
version, 2.13 stdin population.

**Hardening pass (2026-07-20b) added:** the full Claude I/O contract is now
pinned to a hashed raw-docs snapshot (§18); the timeout default is **corrected
to 600 s**; the Kiro global-miss cause is **[R]** as symlink-skip (it is
path-shallowness per #9075) though 2.13 symlink-_follow_ stays [U]; "global
hooks" is **CLI-v3-only** (IDE #5440 still open); and #34692's subagent story is
now bracketed (stale-bot close on 2.1.76 vs current docs). The four §12 [U]s are
unchanged and still need the live probe.

---

## 16. Provenance & method

- **Primary sources fetched/inspected this session:**
  `code.claude.com/docs/en/hooks` (33 events, full I/O contract);
  `kiro.dev/docs/cli/hooks/` (Jun 5, 5 triggers); `kiro.dev/docs/cli/v3/hooks/`
  (Jun 17, 11 triggers); `kiro.dev/changelog/cli/` (2.13.0 global hooks); direct
  `grep` of the `claude-code-2.1.214` and `kiro-cli-2.13.0` store binaries;
  in-repo reads of `mkClaude.nix`, `mkKiro.nix`, `autoMemory.nix`,
  `dir-helpers.nix`, `validate-at-stop.nix`, `model-staleness-claude.nix`,
  `flake.nix`.
- **Research method:** a 7-lens Workflow (claude-inventory, kiro-inventory,
  edge-cases, composition, nix-architecture, testing, why/future) + a dedicated
  drift-detection agent; every claim schema-forced to carry a `source`; 56
  load-bearing claims adversarially verified against primary sources before
  acceptance ([§15]).
- **Machine-checkable provenance going forward** lives in the proposed
  `hook-{events,triggers}.json` sidecars ([§10]) — each fact stamped with the
  binary version and docs-snapshot date it was verified against, re-checked by
  the drift detector on every version bump.
- Full harvested research sections + verdicts: session scratchpad
  `…/scratchpad/harvest/section_*.md`, `verdicts.json` (not committed).

---

## 17. Session handoff & next actions

### ▶ RESUME HERE (next session — hand off THIS doc)

> **⟳ UPDATE 2026-07-20e (session 5 takeover):** the **Claude slice is DONE +
> landed** (C1–C6b, `origin/refactor @ b5f7f74f`) and **C7 (this fold) is
> complete** — §3.1/§7/§6/§8.4 now reflect the landed reality. The remaining
> work is the **Kiro slice**; the live plan of record for it is the "Takeover +
> grading" section of `docs/plans/typed-hooks-phase1-build-plan.md` + memory
> `project_typed_hooks_assessment` SESSION 5. The pre-slice text below is
> retained for provenance.

**State:** all hermetic research + prototypes are **done and committed**. This
doc is the plan of record; §4 + §11.1 + §18 are the hardened, primary-cited
contract; `docs/plans/typed-hooks-research/` holds the citation store
(`primary-source-hardening.md`), the drift-extract prototype, and the **green**
Tier-1b prototype (`tier1b-prototype/`, `nix-build` proven). Memory:
`project_typed_hooks_assessment`.

**The one gate before Phase 1 — HITL live Tier-2 probe (§12 Qs 1–4).** Drive the
Kiro v3 **TUI** + pinned **Claude 2.1.214** in a throwaway _trusted_ project and
observe/dump real stdin, to settle: **Q3** subagent per-tool firing (gates
typing subagent governance — currently `[U]`, bracketed), **Q1** 2.13
global-scan symlink-follow (gates Kiro HM delivery / D6), **Q2** the
actually-implemented 2.13 trigger set, **Q4** Kiro 2.13 stdin population. This
same run **seeds the Tier-1b fixtures** via capture→replay (replace each
fixture's documented `stdin`, flip `provenance` to `captured@<ver>`). Spoon-feed
synchronously (HITL preference). Harness shape: `tier1b-prototype/` +
`dev/scripts/kiro-memory-hitl.sh`.

**Autonomous-ready in parallel (needs no probe):** Phase-1 typed option modules
(§8, per-CLI per D1) for the **D2/D3 PoC subset**; T1 emission golden-tests
extending `checks/module-eval.nix`; promote `tier1b-prototype/` →
`checks/hook-contract-tests.nix` (once real emitted scripts exist — see its
README gate); promote the draft sidecars + wire the advisory binary-grep drift
check (§10). **⚠ These touch factory/check/overlay/flake — coordinate with the
ai.\* factory session that was active during 2026-07-20b;** the
`mkClaude.nix:507` devenv latent bug is already handed to that session
(`typed-hooks-research/handoff-devenv-hooks-bug.md`) — do not duplicate it.

**Decisions:** the §13 recommendations (D1–D10) stand; confirm before Phase 1.
**Guardrails:** no parallel subagent fan-out (OOMs — openmemory MCP per
subagent); single `--max-jobs 1` builds/evals; nixos-config + the live probe are
HITL.

---

**Session 2 (2026-07-20b) — hardening + PoC contract + Tier-1b prototype (this
pass, hermetic; no HITL, no live CLI):**

- **[§18] Primary-source hardening done.** Fetched the raw
  `code.claude.com/docs/en/hooks.md` (232 KB, hashed `509b80…`, no summarizer) +
  the anthropics reference `PreToolUse` impl + re-read GH issues #34692 / Kiro
  #7755 / #5440 / #7737 / #9075. Pinned the full Claude I/O contract (stdin,
  JSON output, exit codes, decision fields, **timeout = 600 s**, matcher eval)
  into §4 as firmly-cited `[C]`; citation store =
  `typed-hooks-research/primary-source-hardening.md`. Kiro no-subagent-hooks now
  `[C]` via a vendor-doc quote (#7755); global-hooks is **CLI-v3-only** (IDE
  #5440 open); the symlink-skip _global-miss_ cause is `[R]` (path-shallowness
  per #9075). **§12 Q3 (subagent-tool firing) stays `[U]`** but is now bracketed
  (docs assert firing + ship `agent_id`; sole repro is 2.1.76 stale-bot close).
- **[§11.1] Per-hook contract filled** for the PoC set — 5 Claude (PreToolUse,
  PostToolUse, UserPromptSubmit, Stop, SessionStart) + 6 Kiro (SessionStart,
  Stop, Pre/PostToolUse, UserPromptSubmit, Manual). Every Claude field is
  CONFIRMED-source; every Kiro stdin field is `⟨probe:Q4⟩`.
- **Tier-1b prototype built + green** at
  `typed-hooks-research/tier1b-prototype/` (NOT wired into `checks/`): a
  validate-at-stop-style harness (`run-contract-tests.sh`) feeds a documented
  stdin payload to a generated hook and asserts stdout/exit; 5 example hooks +
  11 capture→replay fixtures. Runs standalone **and** as a sandboxed
  `runCommandLocal` (`contract-test.nix`, `nix-build` proven:
  `11 passed, 0 failed`; shellcheck `-x` clean). Harness self-verified against 3
  injected corruptions (caught a real `set -e` `a && b` abort during authoring).
  See its `README.md` for the graduation gate.
- **Conflict-safe:** touched only the assessment doc +
  `docs/plans/typed-hooks-research/**` + scratchpad. Did **not** touch any
  factory/check/overlay/flake file; the `mkClaude.nix:507` devenv bug remains
  handed to the factory session (`handoff-devenv-hooks-bug.md`).

**Autonomous gathering completed prior session 1 (hermetic — no HITL, no live
CLI, no commits):**

- **Deep binary extraction** of both pinned binaries (`claude-code 2.1.214`,
  `kiro-cli 2.13.0`).
- **Refinement to §4/§10 (important):** binary-grep reliably extracts the Claude
  **event enum** (exactly 30, confirmed) but is **unreliable for stdin/stdout
  _field_ names** — `stop_hook_active`, `permissionDecision`,
  `last_assistant_message`, `reloadSkills` all return **0** literal hits, yet
  `stop_hook_active` is unquestionably real (the repo's own
  `validate-at-stop.sh` uses it). ⇒ **field schemas must come from the docs
  snapshot, not a binary presence-guard** (the drift detector's
  `schemaFieldMarkers` idea is unsafe for fields; keep it to the event enum).
  Event-enum grep + docs-diff together remain sound.
- **Kiro:** `AgentSpawn` is present as **PascalCase** (7 hits) _and_ camelCase
  (the telemetry enum); the documented `Pre/PostTaskExec` +
  `PostFile{Create,Save,Delete}` triggers are confirmed **absent as literals**
  in 2.13.0, though fragments `taskExec`(59)/`fileSaved`(2) exist → the feature
  may live under different internal naming. Open Q2 remains live.
- **Latent-bug in-repo half CONFIRMED:** `checks/module-eval.nix:67-74,:112`
  stubs **both** `programs.claude-code` and `claude.code` as `attrsOf anything`
  (the comment at `:67` says so) — which is exactly why the `mkClaude.nix:507`
  `//`-merge type mismatch never surfaces. Fix + un-stub in the refactor.
- **Working drift-extraction prototype** (`scratchpad/drift-extract.sh`) run
  end-to-end, producing draft `hooks-surface.json` sidecars for both CLIs
  (`scratchpad/sidecars/`). Validates the whole §10 mechanism on real data:
  advisory tail = 21 Claude events; blocking check = all 9 curated events
  present; Kiro present/absent map emitted. **Ready to promote into
  `packages/*/hooks-surface.json` in Phase 1.**

**Checkpoint state:** research + assessment complete and self-contained (this
doc + memory `project_typed_hooks_assessment`). A fresh session can resume from
here with zero context loss.

**Next actions**

- **HITL-gated (needs you):** the one-time **live Tier-2 probe** for §12 open Qs
  1–4 — drive the Kiro v3 TUI + pinned Claude in a throwaway _trusted_ project,
  observe which triggers actually fire and dump each event's _real_ stdin,
  commit those as capture→replay fixtures. Spoon-fed synchronously (per HITL
  preference). Also HITL: any `nixos-config` change; committing this doc.
- **Autonomous-ready (no HITL):** promote the draft sidecars; write the Phase-1
  typed option modules (§8); add emission golden-tests +
  `validate-at-stop`-style contract tests (§9 Tier 1/1b); wire the advisory
  binary-grep drift check into `flake.nix` + the `extraExtract` regen (§10); fix
  the §3.1/§7 latent devenv bug.
- **Guardrails:** **no parallel subagent fan-out** (that OOM'd twice — each
  subagent spawns an openmemory MCP instance; keep to inline /
  single-`--max-jobs 1` builds, or ≤ a few sequential agents); no commits until
  asked; live probe + `nixos-config` stay HITL.

---

## 18. Primary-source hardening pass (2026-07-20b)

Full citation store:
**`docs/plans/typed-hooks-research/primary-source-hardening.md`** (every fact
anchored to a line in the hashed raw-docs snapshot). Consolidated result:

- **Source of truth:** raw `code.claude.com/docs/en/hooks.md` — 232 221 bytes,
  **sha256 `509b8036585918b0f121b09d0e4ce41952ab778bad794e75c961c14b628a0fca`**,
  `curl` (no summarizer), 2026-07-20; + anthropics
  `examples/hooks/bash_command_validator_example.py` (ref `015170d3`, sha
  `0d7a94…`). This snapshot is the **docs-diff drift baseline** §10 should
  promote in Phase 1.
- **§17's binary-grep mystery resolved:** the "zero-hit" fields
  (`permissionDecision`, `stop_hook_active`, `last_assistant_message`,
  `reloadSkills`) are **doc-defined I/O names, not binary literals** — each has
  multiple hits in the docs (`permissionDecision` ×21, `hookSpecificOutput` ×49,
  `additionalContext` ×40, …). ⇒ the drift detector's `schemaFieldMarkers` guard
  must stay scoped to the **event enum** (binary-embedded); **field schemas come
  from the docs snapshot + Tier-2 captures**, never a binary grep.

**Upgrade ledger:**

| Assessment ref                                                                                   | Was              | Now                                                                                | Basis                      |
| ------------------------------------------------------------------------------------------------ | ---------------- | ---------------------------------------------------------------------------------- | -------------------------- |
| §4.2 stdin (full common set incl. `effort`, `permission_mode` enum, `agent_id`-only-in-subagent) | `[C]` partial    | `[C]` primary-cited                                                                | docs L605                  |
| §4.3 output field names + exit-2-per-event table + JSON-only-on-exit-0                           | `[C]` asserted   | `[C]` each field cited + hit-counted                                               | docs L8-268                |
| §4.3 **timeout default**                                                                         | implied 60 s     | **600 s** (command/http/mcp_tool; prompt 30, agent 60; UPS→30)                     | docs L328 — **correction** |
| §4.4 matcher (3-way charset eval + no-matcher PoC events Stop/UPS)                               | `[C]` prose      | `[C]` exact rule                                                                   | docs L189                  |
| §4.4 subagent-tool firing (#34692)                                                               | `[U]`            | **`[U]` bracketed** (2.1.76 stale-bot close vs current docs w/ `agent_id`)         | hardening §9               |
| §5.5 global hooks                                                                                | `[C]` changelog  | `[C]` + **IDE-vs-CLI split** (IDE #5440 open)                                      | #5440/#7737/#9075          |
| §5.5 symlink-skip as global-miss cause                                                           | `[U]`            | **`[R]`** (cause = path-shallowness #9075); 2.13 symlink-_follow_ still `[U]` (Q1) | #9075                      |
| §5.7 Kiro no-subagent hooks                                                                      | `[C]` docs+#7755 | `[C]` **vendor-doc quote** in #7755                                                | #7755                      |

**Still `[U]` — needs the live Tier-2 probe (§12 Qs 1-4), unchanged by this
pass:** 2.13 global-scan symlink-follow (Q1); exact 2.13 trigger implementation
(Q2); pinned-Claude subagent-tool firing (Q3); 2.13 stdin still metadata-only
(Q4).

**Deliverables of this pass:** §11.1 filled PoC contracts; the citation store;
and the working Tier-1b prototype at
`docs/plans/typed-hooks-research/tier1b-prototype/` (`nix-build` green, unwired
from `checks/`).
