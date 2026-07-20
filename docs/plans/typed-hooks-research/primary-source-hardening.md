# Primary-source hardening pass — Claude hook I/O contract + issue statuses

> **Produced:** 2026-07-20 (session 2, autonomous conflict-safe pass) · read-only research, no HITL, no
> live CLI. Backs the `[U]→[C]` upgrades folded into `typed-hooks-across-clis-assessment.md` §4/§6/§11/§12
> and the §18 hardening ledger. **This file is the citation store for those upgrades** — every fact below
> carries an exact line/section anchor in the fetched primary source so it is re-verifiable.

## Provenance of the fetch

| Source                                              | URL                                                                                                          | Method                  | Size / ref                 | SHA256                                                             |
| --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ | ----------------------- | -------------------------- | ------------------------------------------------------------------ |
| Claude hooks docs (raw markdown, **no summarizer**) | `https://code.claude.com/docs/en/hooks.md`                                                                   | `curl -fsSL` 2026-07-20 | 232 221 bytes / 3125 lines | `509b8036585918b0f121b09d0e4ce41952ab778bad794e75c961c14b628a0fca` |
| Anthropics reference `PreToolUse` hook              | `raw.githubusercontent.com/anthropics/claude-code/015170d3/examples/hooks/bash_command_validator_example.py` | `curl`                  | 2078 bytes                 | `0d7a9468405bb614ebddfb56037217cd9282a8045ea87a42cf6ff4099a61820d` |

The canonical `docs.claude.com/en/docs/claude-code/hooks` **301-redirects** to `code.claude.com/docs/en/hooks`.
Line numbers below index the 3125-line `.md` snapshot (hashed above). The snapshot is the drift-detection
baseline the §10 docs-diff app should promote into `packages/claude-code/hook-events.json` provenance in
Phase 1; it is reproducible byte-for-byte from the pinned `curl` (Mintlify docs are deterministic markdown).

## The §17 mystery, resolved

Session-1 §17 flagged that the **binary** grep returns **0** literal hits for `permissionDecision`,
`stop_hook_active`, `last_assistant_message`, `reloadSkills` — yet `stop_hook_active` is unquestionably real
(the repo's own `lib/validate-at-stop.sh` reads it). This pass confirms **why**: those are **doc-defined I/O
field names, not binary string literals.** Every one has multiple hits in the raw docs:

| Field                      | Raw-docs literal hits |
| -------------------------- | --------------------- |
| `permissionDecision`       | 21                    |
| `hookSpecificOutput`       | 49                    |
| `additionalContext`        | 40                    |
| `updatedInput`             | 11                    |
| `last_assistant_message`   | 9                     |
| `permissionDecisionReason` | 7                     |
| `watchPaths`               | 6                     |
| `updatedToolOutput`        | 6                     |
| `stop_hook_active`         | 5                     |
| `reloadSkills`             | 5                     |
| `initialUserMessage`       | 2                     |

**Design implication (already in §10/§17):** the drift detector's `schemaFieldMarkers` binary-presence guard
is **unsafe for field names** and must stay scoped to the **event enum** (which the binary _does_ embed). Field
schemas come from the **docs snapshot** (this file) + captured Tier-2 fixtures, never from a binary grep.

---

## 1. Common stdin fields — every event (docs §"Common input fields", L605-644) — **[C]**

| Field             | Notes                                                                                                                                                                                           | Min-ver      |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------ |
| `session_id`      | current session id                                                                                                                                                                              | —            |
| `prompt_id`       | UUID of the prompt being processed; **absent until first user input**; matches OTel `prompt.id`                                                                                                 | **v2.1.196** |
| `transcript_path` | conversation JSONL; **written async, may lag** the current turn → use `last_assistant_message` on Stop instead                                                                                  | —            |
| `cwd`             | working dir at hook invocation                                                                                                                                                                  | —            |
| `permission_mode` | one of `default` `plan` `acceptEdits` `auto` `dontAsk` `bypassPermissions`. **"Manual" mode arrives as `"default"`, never `"manual"`.** Not on all events                                       | —            |
| `effort`          | `{ "level": <low / medium / high / xhigh / max> }`; present for **tool-use-context** events (PreToolUse, PostToolUse, Stop, SubagentStop) when the model supports it; also `$CLAUDE_EFFORT` env | —            |
| `hook_event_name` | the event that fired                                                                                                                                                                            | —            |
| `agent_id`        | **present only when the hook fires inside a subagent**; use to distinguish subagent vs main-thread                                                                                              | —            |
| `agent_type`      | agent name; present under `--agent` or inside a subagent (subagent type wins); custom = frontmatter `name`, plugin = `plugin:name` scoped id                                                    | —            |

`model` is delivered **only** to `SessionStart` (and not guaranteed). There is **no `$CLAUDE_MODEL`**. Claude
Code **strips `OTEL_*` exporter vars** from every hook subprocess (L644).

## 2. Universal JSON stdout fields — every event (docs §"JSON output", L90-156) — **[C]**

| Field              | Default | Effect                                                                                                |
| ------------------ | ------- | ----------------------------------------------------------------------------------------------------- |
| `continue`         | `true`  | `false` → Claude stops entirely after the hook; **takes precedence over any event-specific decision** |
| `stopReason`       | none    | shown to user when `continue:false`; **not** shown to Claude                                          |
| `suppressOutput`   | `false` | hides hook stdout from transcript (still in debug log)                                                |
| `systemMessage`    | none    | warning shown to the user                                                                             |
| `terminalSequence` | none    | OSC `0/1/2/9/99/777`+BEL only; anything else ignored (**v2.1.141+**)                                  |

All hook output strings (`additionalContext`, `systemMessage`, plain stdout) are **capped at 10 000 chars**;
overflow is spilled to a file and replaced with a preview+path. The JSON object has three field classes:
**universal** (above), **top-level `decision`/`reason`**, and **`hookSpecificOutput`** (requires a
`hookEventName` field naming the event).

## 3. Exit-code contract (docs §"Exit code output", L8-76) — **[C]**

- **0** = success. **JSON stdout is parsed only on exit 0.** stdout is added to Claude's **context** only for
  `UserPromptSubmit`, `UserPromptExpansion`, `SessionStart`; for all other events stdout → debug log, not
  transcript.
- **2** = blocking error. stdout+JSON ignored; **stderr → Claude**. Per-event effect table below.
- **any other** = non-blocking error → transcript shows `<hook name> hook error` + first stderr line; execution
  continues. **Exception: `WorktreeCreate`, where any non-zero aborts.** (Exit **1 does NOT block** — a common
  trap; confirmed by both docs L34 warning and the anthropics reference impl §7 below.)

**Exit-2 per-event (PoC subset), docs L41-72:**

| Event              | Can block on exit 2? | Effect                                                           |
| ------------------ | -------------------- | ---------------------------------------------------------------- |
| `PreToolUse`       | **Yes**              | blocks the tool call                                             |
| `UserPromptSubmit` | **Yes**              | blocks prompt processing **and erases the prompt**               |
| `Stop`             | **Yes**              | prevents Claude stopping, continues the conversation             |
| `PostToolUse`      | **No**               | shows stderr to Claude; the tool already ran                     |
| `SessionStart`     | **No**               | shows stderr to **user only** (transcript notice as of v2.1.199) |

## 4. Decision control per event (docs §"Decision control" table L196-268 + each event's own §) — **[C]**

| Event                   | Channel                          | Exact fields                                                                                                                                                                                                                                                        |
| ----------------------- | -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `PreToolUse`            | `hookSpecificOutput`             | `permissionDecision` ∈ `{allow,deny,ask,defer}`, `permissionDecisionReason`, `updatedInput` (replaces tool args). **No top-level `decision`.**                                                                                                                      |
| `PostToolUse`           | top-level + `hookSpecificOutput` | `decision:"block"`+`reason` (adds reason next to result; Claude still sees original); `updatedToolOutput` (replaces output, must match tool's output shape); `updatedMCPToolOutput` (MCP-only, prefer `updatedToolOutput`); `additionalContext`                     |
| `UserPromptSubmit`      | top-level                        | `decision:"block"` (erases prompt) + `reason`; `additionalContext`; `sessionTitle`; `suppressOriginalPrompt`. **Cannot replace the prompt** — inject only. Plain stdout also added as context                                                                       |
| `Stop` / `SubagentStop` | top-level + `hookSpecificOutput` | `decision:"block"`+`reason` (required when blocking); **or** `hookSpecificOutput.additionalContext` = non-error feedback that continues the conversation (transcript labels it `Stop hook feedback`, no error notice). Both paths hit the **same loop protections** |
| `SessionStart`          | `hookSpecificOutput`             | `additionalContext`, `initialUserMessage`, `sessionTitle`, `watchPaths`, `reloadSkills`. **No blocking.** Plain stdout also added as context                                                                                                                        |

**PreToolUse blocking is via `permissionDecision:"deny"`, NOT a top-level `decision:"block"`** — this confirms
the session-1 `[R]` verifier correction (verdicts.json) against the raw primary source (docs L202, L235-247).

**Stop loop-guard (docs L13, L90):** `stop_hook_active` is `true` when Claude is already continuing due to a
Stop hook; **Claude Code overrides the hook and ends the turn after 8 consecutive blocks.** This is exactly the
guard `lib/validate-at-stop.sh` implements — the repo's `Stop` hook is a faithful instance of this contract.

## 5. Timeout defaults (docs §"Command hook fields" L328) — **[C] — corrects the assessment's "60s"**

| Handler type                  | Default timeout |
| ----------------------------- | --------------- |
| `command`, `http`, `mcp_tool` | **600 s**       |
| `prompt`                      | 30 s            |
| `agent`                       | 60 s            |

Event overrides: **`UserPromptSubmit`** lowers command/http/mcp_tool → **30 s** (L1123); `MessageDisplay` → 10 s;
`SessionEnd` → 1.5 s (budget raised to the max per-hook timeout, capped 60 s; env
`CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS`). On timeout the hook is canceled, its output (incl.
`additionalContext`) discarded, and the action **proceeds** (fail-open) — except an Agent-SDK `UserPromptSubmit`
callback, which fails-**closed** (blocks). The assessment §11 example said "timeout 600s default" for PreToolUse
(correct) but §11's Kiro-vs-Claude prose and the earlier envelope note implied a 60 s Claude default — **use 600 s**.

## 6. Matcher evaluation (docs §"Matcher patterns" L189-260) — **[C]**

- `"*"`, `""`, or omitted → **match all**.
- charset **only** `[A-Za-z0-9_ \-,|]` → **exact string, or `|`/`,`-separated list of exact strings** (whitespace
  tolerated). e.g. `Edit|Write`, `Edit, Write`.
- **any other char** → **JavaScript unanchored regex** (`RegExp.prototype.test`; matches anywhere → anchor with
  `^…$`).
- Comma separators + whitespace tolerance need **v2.1.191+**; hyphen-in-exact-set needs **v2.1.195+** (older:
  `code-reviewer` is treated as unanchored regex). `FileChanged`/`StopFailure` use a narrower `[A-Za-z0-9_|]` set.

**Per-event matcher target (PoC subset):**

| Event                       | Matcher matches             | Notes                                                   |
| --------------------------- | --------------------------- | ------------------------------------------------------- |
| `PreToolUse`, `PostToolUse` | **tool name**               | `Bash`, `Edit\|Write`, `mcp__.*`                        |
| `SessionStart`              | **how the session started** | `startup` `resume` `clear` `compact`                    |
| `Stop`                      | **no matcher support**      | always fires; a `matcher` field is **silently ignored** |
| `UserPromptSubmit`          | **no matcher support**      | always fires; `matcher` silently ignored                |

Per-handler **`if`** field (permission-rule syntax, e.g. `Bash(git *)`, `Edit(*.ts)`) filters on tool **name+args**
together, on top of the event matcher. Best-effort; fails **open** on unparsable Bash.

## 7. Anthropics reference `PreToolUse` impl (corroborates §3-4) — **[C]**

`examples/hooks/bash_command_validator_example.py` (ref `015170d3`): reads `json.load(sys.stdin)`, keys
`input_data["tool_name"]` and `input_data["tool_input"]["command"]`; **`sys.exit(1)` = "stderr to the user but
not to Claude"** (its own comment), **`sys.exit(2)` = "blocks tool call and shows stderr to Claude."** This is
the canonical vendor pattern the Tier-1b prototype's stub PreToolUse hook mirrors.

## 8. Handler-type availability per PoC event — **[C]**

- `SessionStart` supports **only `command` + `mcp_tool`** handlers (docs L917 "Only type command and mcp_tool
  hooks are supported"). Same for `Setup`.
- `PreToolUse`/`PostToolUse`/`UserPromptSubmit`/`Stop` support all five handler types (`command`, `http`,
  `mcp_tool`, `prompt`, `agent`) per the top-level handler-fields sections.
- MCP-tool hooks work on **every** event once servers connect, but `SessionStart`/`Setup` fire before servers
  finish connecting → expect a "not connected" non-blocking error on first run (docs L113).

---

## 9. GitHub issue statuses (fetched via GitHub API 2026-07-20)

### Claude — `anthropics/claude-code#34692` → Open Q3 (subagent per-tool hooks) — **stays [U], sharper cite**

- Title: _"PreToolUse/PostToolUse hooks do not fire for subagent (Agent tool) tool calls."_
- Reported on **v2.1.76** (Mar 2026). **Closed `not_planned` by `github-actions[bot]` on 2026-05-30** — i.e.
  **stale-bot auto-close, not a maintainer resolution.** 7 comments, 7 👍. Labels: `bug`, `has repro`,
  `area:hooks`, `area:agents`. Its "Suggested Fix" asked for exactly `agent_id`/`parent_agent_id`/`agent_name`.
- **Reconciliation:** the two primary sources now **bracket** the question rather than settle it —
  - **Current docs (2.1.214 era, this fetch)** document `agent_id` (present _only_ inside a subagent) + `agent_type`
    as common stdin fields (§1 above) and state agentic-loop hooks fire in subagents → **docs assert firing**, and
    the exact `agent_id` field the issue requested now exists.
  - **Sole empirical repro (#34692)** says per-tool subagent hooks do **not** fire — but on **2.1.76, five+
    minor versions before our pinned 2.1.214**, and the close is a bot auto-close, not a fix confirmation.
  - ⇒ **Verdict unchanged: `[U]` pending the live 2.1.214 probe (Open Q3).** The upgrade here is _citation
    quality_, not certainty. Do **not** type subagent-tool governance until the probe fires per-tool hooks
    inside an `Agent` call on the pinned binary and inspects stdin for `agent_id`.

### Kiro — subagents (`kirodotdev/Kiro#7755`) → §5.7 / edge-#1 — **now [C] with a vendor-doc quote**

- **OPEN** (feature request), updated 2026-04-30, label `cli`. Body **quotes Kiro's own docs verbatim:**
  _"Steering files and MCP servers work in subagents exactly as they do in the main agent. However, subagents do
  not have access to Specs, and **Hooks will not trigger in subagents**."_
- ⇒ **Kiro hooks not firing in subagents is [C] (vendor doc quote), and the request to change it is unresolved/open.**
  Independent of the Claude story — the "both CLIs fail in subagents" framing remains wrong (Claude docs assert
  firing; Kiro docs assert non-firing).

### Kiro — global-hooks discovery (`#5440` open, `#7737`+`#9075` closed) → §5.5 — **status folded**

| Issue                                                  | Product | State                                                                                                     | Signal                                                                                                                                                                                                                                                                                                                          |
| ------------------------------------------------------ | ------- | --------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `#5440` "Support for Global Hooks (~/.kiro/hooks/)"    | IDE     | **OPEN**, upd **2026-07-16**, 48 👍, labels `hooks`/`usability`/`pending-maintainer-response`/`keep-open` | The canonical global-hooks tracker; **still open for the IDE** the day before the 2.13.0 **CLI** changelog                                                                                                                                                                                                                      |
| `#7737` "Support global hooks…"                        | IDE     | CLOSED `completed`-as-**duplicate** 2026-04-26 (bot)                                                      | "Hooks… are workspace-scoped only (.kiro/hooks/)"                                                                                                                                                                                                                                                                               |
| `#9075` "Agent hooks not discovered in ~/.kiro/hooks/" | IDE     | CLOSED `completed`-as-**duplicate** 2026-06-06 (bot)                                                      | **Root cause = LOCATION**, not symlinks: scan looks for `<folder>/.kiro/hooks/`; `~/.kiro` _is_ the `.kiro` dir so the effective path is `~/.kiro/.kiro/hooks/` → `~/.kiro/hooks/` is one level too shallow. **A real file at `~/.kiro/hooks/` also fails.** Skills (`~/.kiro/skills/`) + Steering load globally; hooks did not |

**Two load-bearing conclusions for §5.5:**

1. **"Global hooks" is CLI-v3-only.** The 2.13.0 _CLI_ changelog added `~/.kiro/hooks/` firing ("Available in V3
   `kiro-cli --v3`"); the _IDE_ tracker `#5440` is **still open** as of 2026-07-16. Don't generalize the CLI
   changelog to the IDE.
2. **The symlink-skip mechanism is refuted as the cause of the global miss** (verdicts.json already `[U]`-flagged
   it): `#9075` shows a **real** file at `~/.kiro/hooks/` is undiscovered → the failure is **path shallowness**,
   not symlink-following. Whether the _new 2.13.0 workspace/global scan follows store symlinks_ (Open Q1, gates
   HM `home.file` delivery) is a **separate, still-unverified** question — no issue speaks to it; only a live
   2.13.0 test settles it.

---

## 10. `[U]→[C]` upgrade ledger (what this pass changed in the assessment)

| Assessment ref                        | Was                  | Now                                                                                          | Basis                                                    |
| ------------------------------------- | -------------------- | -------------------------------------------------------------------------------------------- | -------------------------------------------------------- |
| §4.2 stdin contract                   | `[C]` (partial list) | `[C]` (full, primary-cited)                                                                  | §1 above (docs L605)                                     |
| §4.3 output field names               | `[C]` (asserted)     | `[C]` (each field primary-cited + hit-counted)                                               | §2, §4 above                                             |
| §4.3 exit-2-per-event                 | `[C]`                | `[C]` (full table)                                                                           | §3 above (docs L41-72)                                   |
| Timeout default                       | implied 60 s         | **600 s** command/http/mcp_tool                                                              | §5 (docs L328) — **correction**                          |
| §4.4 matcher eval + no-matcher events | `[C]` (prose)        | `[C]` (exact charset rule + per-event target)                                                | §6 (docs L189)                                           |
| §4.4 subagent-tool firing (#34692)    | `[U]`                | **`[U]` (sharper cite; bracketed)**                                                          | §9 — stale-bot close on 2.1.76; docs now have `agent_id` |
| §5.7 / edge-#1 Kiro no-subagent hooks | `[C]` (docs+#7755)   | `[C]` (vendor-doc **quote** in #7755)                                                        | §9                                                       |
| §5.5 global hooks                     | `[C]` (changelog)    | `[C]` + **IDE-vs-CLI split** + symlink-cause refuted                                         | §9                                                       |
| §5.5 symlink-skip mechanism           | `[U]`                | **still `[U]`** (cause refuted for the _global_ miss; the 2.13 symlink-follow Q is separate) | §9, Open Q1                                              |

**Stays `[U]` (needs the live probe — Open Qs 1-4):** 2.13 global scan symlink-follow (Q1); which Kiro triggers
2.13.0 actually implements (Q2); pinned-Claude subagent-tool firing (Q3); Kiro 2.13 stdin still metadata-only (Q4).
