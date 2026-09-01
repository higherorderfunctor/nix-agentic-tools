# Claude Code & Kiro CLI Hooks: Complete Inventory + Nix Typing Gap Analysis

## Executive Summary

This assessment catalogs the complete hook landscape for Claude Code and Kiro
CLI, specifies the JSON input/output schemas and matcher semantics, audits the
current Nix typing surface in nix-agentic-tools, and identifies the gap between
today's **untyped passthrough** and a goal of **per-event typed options** that
can support telemetry, auto-memory, and workflow optimization.

**Key finding:** The factory ships `ai.claude.hooks` and `ai.kiro.hooks` as
`attrsOf lines` (raw script/JSON bodies), routed to untyped `settings.hooks`
(Claude) and `.kiro/hooks/<name>.json` (Kiro). Neither backend provides typed
schema validation. Kiro's inline comments (mkKiro.nix:275-327) already recognize
this as a **GREENFIELD** gap: "there is no upstream format we wrap — Kiro OWNS
these schemas — so a future session should MODEL them typed."

---

## Part 1: Claude Code Hooks — Complete Event Inventory

### Official Reference

Source: https://code.claude.com/docs/en/hooks.md (fetched 2026-07-20)

Claude Code fires hooks at **three cadences**:

- **Per-session:** `SessionStart`, `SessionEnd`, `Setup`
- **Per-turn:** `UserPromptSubmit`, `UserPromptExpansion`, `Stop`, `StopFailure`
- **Per-tool-call:** `PreToolUse`, `PostToolUse`, `PostToolUseFailure`,
  `PostToolBatch`, `PermissionRequest`, `PermissionDenied`
- **Life-cycle events:** `SubagentStart`, `SubagentStop`, `TaskCreated`,
  `TaskCompleted`, `PreCompact`, `PostCompact`, `InstructionsLoaded`
- **I/O & notifications:** `FileChanged`, `CwdChanged`, `ConfigChange`,
  `Notification`, `MessageDisplay`, `WorktreeCreate`, `WorktreeRemove`
- **MCP elicitation:** `Elicitation`, `ElicitationResult`
- **Teammate idle:** `TeammateIdle`

**Total: 30 distinct hook events** (per official docs).

### Hook Event Specifications

#### Session-Scoped Events

| Event            | Trigger                                  | Matcher                                                | Input Schema                                                                     | Capabilities                                                                                          | Exit Codes                          | Notes                              |
| ---------------- | ---------------------------------------- | ------------------------------------------------------ | -------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- | ----------------------------------- | ---------------------------------- |
| **SessionStart** | Session begins/resumes                   | `startup`, `resume`, `clear`, `compact`                | `{session_id, transcript_path, cwd, source, model, agent_type?, session_title?}` | ✅ Inject context via `additionalContext`; set title; watch files; reload skills; set initial message | `0` success, `2` non-blocking error | Once per session                   |
| **SessionEnd**   | Session terminates                       | `clear`, `resume`, `logout`, `prompt_input_exit`, etc. | `{session_id, cwd, reason}`                                                      | ❌ No blocking                                                                                        | `0` success, `2` error              | Cleanup only; no output processing |
| **Setup**        | `--init-only`, `--init`, `--maintenance` | `init`, `maintenance`                                  | `{session_id, cwd}`                                                              | ✅ Context injection; one-time prep                                                                   | `0` success, `2` error              | CI/script setup                    |

#### Turn-Scoped Events (Per-Prompt)

| Event                   | Trigger                                               | Matcher                                                                | Input Schema                                                  | Capabilities                                                                            | Exit Codes              | Output                                  |
| ----------------------- | ----------------------------------------------------- | ---------------------------------------------------------------------- | ------------------------------------------------------------- | --------------------------------------------------------------------------------------- | ----------------------- | --------------------------------------- |
| **UserPromptSubmit**    | User submits prompt                                   | N/A (always fires)                                                     | `{session_id, prompt_id, cwd, permission_mode, prompt}`       | ✅ Block via `decision: "block"` + `reason`; ✅ inject context; ❌ cannot modify prompt | `0` allow, `2` block    | `{decision, reason, additionalContext}` |
| **UserPromptExpansion** | Command (e.g. `/skill`) expands before Claude sees it | Command name                                                           | `{session_id, prompt_id, cwd, command_name, expanded_prompt}` | ✅ Block via `decision: "block"`; ✅ context injection                                  | `0` allow, `2` block    | Same shape as UserPromptSubmit          |
| **Stop**                | Claude finishes responding                            | N/A (always fires)                                                     | `{session_id, prompt_id, cwd, last_assistant_message}`        | ✅ Prevent stop via `decision: "block"`; ✅ inject context shown after response         | `0` continue, `2` block | `{decision, reason, additionalContext}` |
| **StopFailure**         | Turn ends due to API error                            | Error type (`rate_limit`, `overloaded`, `authentication_failed`, etc.) | `{session_id, cwd, error_type, error_message}`                | ❌ No output processing (error already occurred); ✅ logging only                       | N/A                     | N/A                                     |

#### Tool-Call Events

| Event                  | Trigger                                         | Matcher                                    | Input Schema                                                                                     | Capabilities                                                                                                                                | Exit Codes                                  | Output                                                                            |
| ---------------------- | ----------------------------------------------- | ------------------------------------------ | ------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------- | --------------------------------------------------------------------------------- |
| **PreToolUse**         | Before tool executes                            | Tool name (e.g., `Bash`, `Edit`, `mcp__*`) | `{session_id, prompt_id, cwd, permission_mode, tool_name, tool_input}`                           | ✅ Deny/allow/ask via `permissionDecision`; ✅ modify input via `updatedInput`; ✅ context injection; ❌ tool always executes if not denied | `0` process JSON, `2` blocking error        | `{permissionDecision, permissionDecisionReason, updatedInput, additionalContext}` |
| **PermissionRequest**  | Permission dialog appears                       | Tool name                                  | Same as PreToolUse                                                                               | ✅ Allow/deny on behalf of user; ✅ modify input; ✅ apply permission rules                                                                 | `0` process, `2` error                      | `{decision: {behavior, updatedInput}, permissionRules}`                           |
| **PermissionDenied**   | Tool denied by auto-mode                        | Tool name                                  | `{session_id, cwd, tool_name, tool_input}`                                                       | ✅ Allow retry via `retry: true`                                                                                                            | `0` process                                 | `{retry: bool}`                                                                   |
| **PostToolUse**        | After tool succeeds                             | Tool name                                  | `{session_id, prompt_id, cwd, tool_name, tool_input, tool_output}`                               | ✅ Block further processing via `decision: "block"`; ✅ modify output via `updatedToolOutput`; ✅ context injection                         | `0` success, other codes non-blocking error | `{decision?, reason?, updatedToolOutput?, additionalContext?}`                    |
| **PostToolUseFailure** | After tool fails                                | Tool name                                  | `{session_id, prompt_id, cwd, tool_name, tool_input, tool_error}`                                | ✅ Block; ✅ modify error via `updatedToolOutput`; ✅ context injection                                                                     | `0` success, other codes error              | Same shape as PostToolUse                                                         |
| **PostToolBatch**      | After parallel batch resolves before model call | N/A (always fires)                         | `{session_id, prompt_id, cwd, tool_calls: [{tool_name, tool_input, tool_output/tool_error}...]}` | ✅ Stop loop via `decision: "block"`                                                                                                        | `0` continue, `2` block                     | `{decision?, reason?}`                                                            |

#### Subagent & Task Events

| Event             | Trigger                       | Matcher                                                | Capabilities                                                         | Output                                     |
| ----------------- | ----------------------------- | ------------------------------------------------------ | -------------------------------------------------------------------- | ------------------------------------------ |
| **SubagentStart** | Subagent spawned              | Agent type (e.g. `general-purpose`, `Explore`, custom) | ✅ Context injection; ❌ no blocking (already spawned)               | `{additionalContext?}`                     |
| **SubagentStop**  | Subagent finishes             | Agent type                                             | ✅ Prevent stop via `decision: "block"`; ✅ context injection        | `{decision?, reason?, additionalContext?}` |
| **TaskCreated**   | Task created via `TaskCreate` | N/A (always fires)                                     | ✅ Rollback via `decision: "block"` or exit code 2; ❌ cannot modify | `{decision?}`                              |
| **TaskCompleted** | Task marked done              | N/A (always fires)                                     | ✅ Prevent completion via `decision: "block"` or exit code 2         | `{decision?}`                              |

#### Compaction & Instructions

| Event                  | Trigger                                  | Matcher                                                                      | Input Schema                                 | Capabilities                                                          | Output                                     |
| ---------------------- | ---------------------------------------- | ---------------------------------------------------------------------------- | -------------------------------------------- | --------------------------------------------------------------------- | ------------------------------------------ |
| **PreCompact**         | Before context compaction                | `manual`, `auto`                                                             | `{session_id, cwd, triggered_by}`            | ✅ Block via `decision: "block"` or exit code 2; ✅ context injection | `{decision?, reason?, additionalContext?}` |
| **PostCompact**        | After compaction completes               | `manual`, `auto`                                                             | `{session_id, cwd, triggered_by}`            | ❌ No blocking; ✅ logging/side effects only                          | N/A                                        |
| **InstructionsLoaded** | CLAUDE.md or `.claude/rules/*.md` loaded | `session_start`, `nested_traversal`, `path_glob_match`, `include`, `compact` | `{session_id, cwd, triggered_by, file_path}` | ❌ No blocking/modification; ✅ logging only                          | N/A                                        |

#### File & Environment Events

| Event            | Trigger                                      | Matcher                                                                            | Input Schema                   | Capabilities                                                                      | Output                                     |
| ---------------- | -------------------------------------------- | ---------------------------------------------------------------------------------- | ------------------------------ | --------------------------------------------------------------------------------- | ------------------------------------------ |
| **FileChanged**  | Watched file changes on disk                 | Literal filenames (e.g., `.envrc\|.env`)                                           | `{session_id, cwd, file_path}` | ✅ Reactive env management; ❌ no blocking                                        | N/A                                        |
| **CwdChanged**   | Working directory changes (e.g., after `cd`) | N/A (always fires)                                                                 | `{session_id, cwd}`            | ✅ Reactive env (direnv, etc.); ❌ no blocking                                    | N/A                                        |
| **ConfigChange** | Config file changes during session           | `user_settings`, `project_settings`, `local_settings`, `policy_settings`, `skills` | `{session_id, cwd, source}`    | ✅ Block via `decision: "block"` (except `policy_settings`); ✅ context injection | `{decision?, reason?, additionalContext?}` |

#### Worktree & Notifications

| Event              | Trigger                                                       | Matcher                                                                                            | Capabilities                                                                                                                        | Output                |
| ------------------ | ------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- | --------------------- |
| **WorktreeCreate** | Worktree creation via `--worktree` or `isolation: "worktree"` | N/A (always fires)                                                                                 | ✅ Return path via `worktreePath` field or stdout; ✅ exit code 2 or missing path = creation fails; ✅ replace default git behavior | `{worktreePath}`      |
| **WorktreeRemove** | Worktree removal                                              | N/A (always fires)                                                                                 | ❌ No blocking (already initiated); ✅ logging only                                                                                 | N/A                   |
| **Notification**   | Claude Code sends notification                                | Notification type (`permission_prompt`, `idle_prompt`, `auth_success`, `elicitation_dialog`, etc.) | ✅ Terminal notifications via `terminalSequence`; ❌ no blocking                                                                    | `{terminalSequence?}` |
| **MessageDisplay** | While assistant message text displays                         | N/A (always fires)                                                                                 | ✅ Replace displayed text via `displayContent`; ❌ transcript keeps original                                                        | `{displayContent?}`   |

#### MCP Elicitation & Teammate

| Event                 | Trigger                                                          | Matcher            | Capabilities                                                                            | Output                                          |
| --------------------- | ---------------------------------------------------------------- | ------------------ | --------------------------------------------------------------------------------------- | ----------------------------------------------- |
| **Elicitation**       | MCP server requests user input during tool call                  | MCP server name    | ✅ Accept/decline/cancel via `action`; ✅ provide form values via `content`             | `{action: "accept\|decline\|cancel", content?}` |
| **ElicitationResult** | User responds to MCP elicitation, before response sent to server | MCP server name    | ✅ Override response via `action` + `content`; ✅ block via `action: "decline\|cancel"` | `{action, content?}`                            |
| **TeammateIdle**      | Agent team teammate about to go idle                             | N/A (always fires) | ✅ Prevent idle via `decision: "block"` or exit code 2                                  | `{decision?}`                                   |

---

## Part 2: Kiro CLI v3 Hooks

### Official Schema

Source: mkKiro.nix:292-298 (local specification) + autoMemory.nix (reference
implementation showing live v3 usage)

**Kiro v3 hook schema** (`<configDir>/hooks/<name>.json`):

```json
{
  "version": "v1",
  "hooks": [
    {
      "name": "hook-id",
      "description": "optional hook description",
      "trigger": "SessionStart | Stop | PreToolUse | PostToolUse | PreTaskExec | PostTaskExec | UserPromptSubmit | PostFileCreate | PostFileSave | PostFileDelete | Manual",
      "matcher": "optional-glob-pattern",
      "action": {
        "type": "command | agent",
        "command": "/path/to/command",
        "prompt": "agent prompt if type=agent"
      },
      "timeout": 60,
      "enabled": true
    }
  ]
}
```

**Kiro v3 confirmed hook events** (from production auto-memory):

- `Stop` — per-turn, fires after Claude finishes; input: `{session_id, cwd}`;
  used for debounced auto-distill
- `SessionStart` — per-session startup; input: `{session_id, cwd}`; used for
  tail-flush from prior sessions
- `UserPromptSubmit` — per-turn before prompt submission; input:
  `{session_id, cwd}` (prompt field empty—D12); used for memory recall injection
- `Manual` — user-triggered via `/remember`; same as Stop but with force flag;
  input metadata-only

**Critical constraints (docs/plans/kiro-v3-hooks.md, confirmed by
autoMemory.nix):**

1. **Workspace-local real files only:** Kiro v3 discovers hooks by scanning
   `<cwd>/.kiro/hooks/` with `read_dir`; store symlinks are skipped, global
   `~/.kiro/hooks/` is ignored (issues kirodotdev/Kiro #5440, #7737, #9075)
2. **Hook stdin = metadata-only:** No prompt content, no full context; seeds
   from session metadata for archive queries (D12)
3. **No SessionEnd hook:** v3 fires Stop **per-turn**, not at end; final
   sub-threshold tail requires debounce OR-gate + cross-session flush to not
   drop (D24, autoMemory.nix:24)
4. **One envelope per file:** Multiple hooks bundled in a single
   `{ version, hooks:[...] }` JSON file works (confirmed live 2026-07-14); no
   per-hook split required

**Kiro v2 embedded hooks** (backwards compatibility):

- Still work transitionally; `kiro-cli agent migrate` converts to v3 schema
- `trustedMcpTools` list auto-translated to v3 `permissions` under v3 active
  (mkKiro.nix:33-68)

---

## Part 3: Current Nix Typing Surface in nix-agentic-tools

### Claude Hooks (packages/claude-code/lib/mkClaude.nix:250-281)

```nix
hooks = lib.mkOption {
  type = lib.types.attrsOf lib.types.lines;  # ← UNTYPED script bodies
  default = {};
  description = "Claude hook shell scripts. Attribute name becomes hook filename; value is the script body.";
};

hooksDir = lib.mkOption {
  type = lib.types.nullOr dirOptionType;  # ← Accepts path or { path, filter? }
  default = null;
  description = "Claude hook scripts directory.";
};
```

**Routing:**

- **HM:** `ai.claude.hooks` → `programs.claude-code.hooks` (upstream writes to
  `~/.claude/hooks/<name>` shell script files)
- **Devenv:** `ai.claude.hooks` → `claude.code.hooks` (merged with legacy
  `settings.hooks` for backward compat; both written to settings.json by
  upstream)

**Current gap:** No per-event validation, no matcher support, no capability
specification. Consumers write raw bash with no schema guidance.

### Kiro Hooks (packages/kiro-cli/lib/mkKiro.nix:314-327)

```nix
hooks = lib.mkOption {
  type = lib.types.attrsOf (lib.types.either lib.types.lines lib.types.path);
  default = {};
  description = "Hook JSON definitions (written to <configDir>/hooks/<name>.json).";
};

hooksDir = lib.mkOption {
  type = lib.types.nullOr lib.types.path;
  default = null;
  description = "External directory of hook JSON files (symlinked into <configDir>/hooks).";
};
```

**Routing:**

- **HM:** `ai.kiro.hooks` → `home.file.<configDir>/hooks/<name>.json`
  (symlinked)
- **Devenv:** `ai.kiro.hooks` → `enterShell install -m 0644` as **REAL files**,
  not devenv `files.*` (symlinks); critical because v3 skips store symlinks
  (mkKiro.nix:643-658; autoMemory.nix invariant #11)

**Inline comment** (mkKiro.nix:275-282):

> "GREENFIELD (held — see docs/plans/kiro-v3-permissions.md). These are UNTYPED
> PASSTHROUGH today: we write whatever JSON the consumer authors. There is no
> upstream format we wrap — Kiro OWNS these schemas — so a future session should
> MODEL them typed (like `permissions`), not passthrough."

**Critical devenv gotcha:** The HM global install (`~/.kiro/hooks/`) never loads
under v3; only project-local `.kiro/hooks/` loads. Devenv's real-file workaround
ensures delivery, but HM consumers expecting global hooks see nothing.

### Auto-Memory Example: Reference Hook Implementation

Source: packages/kiro-cli/lib/autoMemory.nix (156-238) — a working consumer
proving the schema.

The four lifecycle hooks ship as one `kiro-memory.json` envelope:

```nix
hookEnvelope = {
  version = "v1";
  hooks = [
    (mkHook {
      name = "kiro-memory-distill";
      trigger = "Stop";
      command = "${stopWrapper}";
      description = "Distill this session's new turns into ~/.kiro-memory (debounced, per-turn).";
    })
    # ... SessionStart, Manual, UserPromptSubmit
  ];
};
```

**Entry schema** (mkHook function):

```nix
mkHook = { name, trigger, command, description }: {
  inherit name description trigger timeout;
  enabled = true;
  action = {
    type = "command";
    inherit command;
  };
};
```

The wrappers are shell scripts with absolute store paths (nix-standards), strict
mode, and HOME guards (autoMemory.nix:90-136). This proves:

- Real hooks ARE JSON files
- The command field accepts absolute store paths
- Multiple hooks per file works
- No prompt-based hook evaluation in Kiro (unlike Claude's prompt-based hook
  type)

---

## Part 4: Stop-Hook Validation as Verification Precedent

Source: checks/validate-at-stop.nix + lib/validate-at-stop.sh

This hermetic check demonstrates hook verification WITHOUT live CLI invocation:

**Design:**

- Feeds a JSON payload on stdin:
  `{"cwd":"...", "stop_hook_active":false, "hook_event_name":"Stop"}`
- Stubs git-hooks tools (treefmt, cspell) so no external dependencies needed
- Tests Stop-hook orchestration: no-diff → silent; fixable lint → auto-fix, no
  block; fatal lint → block with reason; repeated failure → loop-guard, no block
- Uses `shellcheck -x` (matching pre-commit standard)
- **Exit code 0 on success**, fixtures under `checks/fixtures/claude-hooks/`

**Load-bearing:** The loop-guard test (T4) proves the `stop_hook_active` field
gates re-entry; this design pattern is portable to other hooks.

---

## Part 5: Gap Analysis — Current State vs. Typed Goal

### The Untyped Present

| Surface                   | Type                          | Example                                  | Validation                          | Matcher Support                |
| ------------------------- | ----------------------------- | ---------------------------------------- | ----------------------------------- | ------------------------------ |
| `ai.claude.hooks`         | `attrsOf lines`               | Raw bash script bodies as strings        | ❌ None                             | ❌ Implicit filename-based     |
| `ai.kiro.hooks`           | `attrsOf (either lines path)` | Raw JSON string or file path             | ❌ None (consumer's responsibility) | ❌ None (Kiro reads all files) |
| `settings.hooks` (Claude) | Freeform JSON                 | User-editable at runtime; no schema      | ❌ None                             | ❌ None                        |
| `permissions` (Kiro v3)   | **Typed submodule** ✅        | `{capability, effect, match?, exclude?}` | ✅ Per-field enum + shape           | ✅ Structured match arrays     |

**Key insight:** `ai.kiro.permissions` (mkKiro.nix:220-266) IS typed per-event;
hooks are the GREENFIELD gap.

### The Typed Goal

For each hook event (Claude: 30 events × multiple cadences; Kiro: ~9 events × 1
schema):

**Nix option shape** (sketch):

```nix
ai.claude.hooks = {
  type = lib.types.attrsOf (lib.types.submodule {
    options = {
      trigger = lib.mkOption {
        type = lib.types.enum ["SessionStart" "UserPromptSubmit" "PreToolUse" ...];
        description = "When this hook fires.";
      };
      matcher = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        description = "Tool name pattern or regex.";
      };
      handler = lib.mkOption {
        type = lib.types.submodule { /* input/output schemas */ };
        description = "Shell command or HTTP endpoint.";
      };
      # Field-level validation for known events
      capabilities = lib.mkOption {
        type = lib.types.listOf (lib.types.enum ["block" "inject_context" "modify_output" ...]);
        description = "What this hook is allowed to do.";
      };
    };
  });
};
```

**Emit shape** (after validation):

- **Claude HM:** Each hook → `~/.claude/hooks/<name>` shell script
- **Claude Devenv:** Each hook → `.claude/settings.json` entry under `hooks` key
- **Kiro HM/Devenv:** Each hook → `.kiro/hooks/<name>.json` (per-event or
  multi-hook envelope)

### Decisions Required from the Principal Engineer

**1. Per-Event vs. Envelope**

- **Per-event:** One hook JSON file per event type (verbose, clear intent, easy
  schema per event)
- **Envelope:** Single `hooks.json` with `[{name, trigger, ...}]` array (matches
  live auto-memory pattern, proven to work)
- **Recommendation:** Envelope. autoMemory.nix proves it works; reduces file
  proliferation.

**2. Typed Schema Source of Truth**

- Inline Nix submodules (load-bearing definition lives in factory; full control)
- External JSON Schema file (single source for validation tools; harder to keep
  in sync)
- **Recommendation:** Nix submodules for both Claude and Kiro, with optional
  JSON export for CI/docs.

**3. Matcher Type**

- **String patterns** (`tool_name`, `server/*`, `regex:.*pattern`)
- **Structured enum + glob** (like `permissions.match` — explicit list of
  strings, no regex)
- **Recommendation:** Glob patterns (simpler, matches existing Kiro precedent in
  permissions); consider regex as escape hatch for power users.

**4. Validation & Verification**

- **Live CLI verification:** Run claude/kiro in sandbox, trigger events, capture
  behavior (expensive, burns tokens for Claude)
- **Static schema check:** Validate Nix option shape, exit codes, output field
  names (fast, hermetic)
- **Stub-based integration test:** Feed test payloads on stdin, validate output
  (precedent: validate-at-stop.nix)
- **Recommendation:** Combination: static schema check in `nix flake check`
  (fast path); stub-based integration tests for each event type (slow path, but
  catches orchestration bugs); live CLI tests as manual/CI gate (expensive, only
  for breaking changes).

**5. Scope Phasing**

- **Phase 0 (This assessment):** Inventory complete, gaps identified
- **Phase 1:** Schema design + Nix option declarations (both Claude and Kiro)
- **Phase 2:** Static validation checks (`checks/module-eval.nix` extensions)
- **Phase 3:** Stub-based integration fixtures (one per event type, test
  input/output contracts)
- **Phase 4:** Auto-memory + telemetry consumers (consume typed hooks for event
  filtering, metric emission)
- **Phase 5:** Live CLI verification (CI gate, manual approval needed;
  expensive)
- **Recommendation:** Sequence Phase 1-3 in one sprint; Phase 4-5 are consumer
  work.

**6. Backward Compatibility**

- Keep `ai.claude.hooks = attrsOf lines` and
  `ai.kiro.hooks = attrsOf (either lines path)` as legacy fallback (silent
  accept, no validation)
- New typed axis parallel to legacy (e.g., `ai.claude.hooksTyped` or reuse same
  option name with union type)
- **Recommendation:** Reuse same option name (`ai.claude.hooks`,
  `ai.kiro.hooks`) with a union type: `oneOf [legacyType typedType]` so
  consumers don't fork. Deprecation notice in the legacy arm.

**7. Claude Prompt-Based Hooks**

- Official docs list a `prompt`-type hook (LLM-evaluated).
- Current factory has NO support for this (only shell commands).
- **Recommendation:** DEFER. Prompt-based hooks require model invocation, token
  cost tracking, and semantic validation—out of scope for initial schema work.
  Phase 1 covers shell + HTTP + agent types only; prompt is Phase 2+.

**8. Kiro v2 Backward Compat**

- v2 embedded hooks (transitional, auto-migrate to v3 schema).
- Factory has NO v2-specific schema (intentional, v3 is primary).
- **Recommendation:** DEFER. Mark v2 support as transitional; v2 users get
  auto-migration prompt but no new Nix typing. v3 is typed.

---

## Part 6: Upstream Nixpkgs Status & Integration Points

### programs.claude-code (Home Manager)

**Finding:** Nixpkgs home-manager module `programs.claude-code` exists and is
actively maintained (PR #7711, merged 2025). The upstream module provides:

- `enable`, `package`
- `skills`, `agents`, `commands` (directory sources)
- `hooks` (passthrough to settings.json)
- `context`, `plugins`, `marketplaces`, `outputStyles`
- `settings` (freeform JSON)
- `lspServers`

**Upstream hook handling:** The HM module writes hooks directly to settings.json
via `programs.claude-code.hooks` (freeform pass-through). No schema, no
validation.

**Gap for nix-agentic-tools:** The factory sits BETWEEN the consumer and
upstream. It provides the typed options (`ai.claude.hooks`), then renders to the
freeform shape upstream expects:

```nix
# mkClaude.nix HM projection (lines 350-356):
programs.claude-code = {
  enable = lib.mkDefault true;
  package = lib.mkDefault cfg.package;
  skills = lib.mapAttrs (_: lib.mkDefault) mergedSkills;
  hooks = cfg.hooks;  # ← direct passthrough today; would be `renderHooks cfg.hooks` if typed
  # ...
};
```

If the factory implements typed hooks, the rendering step becomes:

```nix
hooks = lib.mapAttrs renderHookToShellScript cfg.hooks;  # type → shell script
```

### programs.kiro-cli (Home Manager)

**Status:** Nixpkgs does NOT provide a `programs.kiro-cli` HM module (unlike
claude-code). The project implements its own HM module via mkKiro.nix + the
factory pattern.

**Kiro hook handling:** The factory writes hooks directly to
`.kiro/hooks/<name>.json` via `home.file` (HM) or `enterShell install` (devenv).

**Integration point:** Adding typed Kiro hooks requires NO upstream change—the
factory owns the full emit pipeline.

### Devenv Integration

**Claude:** Upstream `claude.code` is a simple options struct, NOT a full HM
module. The factory passes hooks to `claude.code.hooks` (merged with
settings.json).

**Kiro:** No upstream devenv module; factory owns it via `files.*` and
`enterShell`.

---

## Part 7: Known Edge Cases & Constraints

### Edge Case 1: Kiro v3 Hooks Must Be REAL Files in Workspace

**Constraint:** Kiro v3 scans `.kiro/hooks/` with `read_dir`, skips store
symlinks, ignores global `~/.kiro/hooks/`.

**Impact on devenv:**

- HM global install (symlink via `home.file`) does NOT load under v3.
- Devenv project-local (real files via `enterShell install`) DOES load.
- **Current workaround:** mkKiro.nix devenv uses `install -m 0644` (lines
  643-658) instead of `files.*` (which would symlink).

**Typed schema implication:** Emit logic must detect Kiro v3 (check
`cfg.v3 || cfg.tui`) and force real-file emit in devenv, never symlink.

### Edge Case 2: Claude Stop Hook vs. Kiro Stop Hook

**Difference:**

- Claude Stop: fires at END of turn after Claude finishes responding. Payload
  includes full `last_assistant_message`. Can block to prevent the turn from
  ending.
- Kiro Stop: fires AFTER each turn (per-turn debounce). Payload is metadata-only
  (`{session_id, cwd}`). Cannot access the LLM response.

**Schema implication:** Input schema differs; capabilities differ. Not
interchangeable.

### Edge Case 3: Kiro Manual Trigger (Not a Real Event)

**Status:** `/remember` is a user-triggered action (menu item), not a native
Kiro hook event like SessionStart or Stop.

**Handling in auto-memory:** The Manual wrapper is the SAME as Stop but with
`KIRO_MEMORY_FORCE=1` baked (autoMemory.nix:146-149, invariant #10). Distiller
respects the force flag.

**Schema implication:** `trigger = "Manual"` is valid in Kiro's schema; it's a
second invocation of the same distiller logic, not a separate event type.

### Edge Case 4: Claude Prompt-Based Hooks (Deferred)

**Status:** Official docs mention `"prompt"` type hooks (LLM-evaluated
condition). Factory has NO support for these today.

**Why deferred:**

- Requires model invocation, token cost tracking, and semantic validation.
- autoMemory (current consumer) uses shell commands only, not prompts.
- Prompt-based hooks introduce new complexity: which model? which cost tracking?
  how to cache?

**Recommendation:** DEFER to Phase 2+; Phase 1 covers shell + HTTP + agent types
(Claude) and command + agent types (Kiro).

### Edge Case 5: Hook Scoping to Agents / Skills

**Status:** Unclear from official docs whether hooks can be scoped to specific
agents or skills (e.g., "only fire this PreToolUse hook when an Explore agent is
active").

**Current factory:** No per-agent/skill hook scoping. Hooks are global to the
CLI.

**Recommendation:** DEFER. Clarify with Anthropic/Kiro docs; add to Phase 2+ if
confirmed needed.

### Edge Case 6: TUI vs. Headless Mode

**Status:** Claude Code & Kiro v3 both have TUI mode. Unknown whether hooks fire
the same way in headless (API) mode vs. TUI.

**Current factory:** No distinction; hooks treated as universal.

**Recommendation:** DEFER. Clarify firing semantics; if different, add
conditional logic.

### Edge Case 7: Claude Nested Hooks (Pre/PostCompact, InstructionsLoaded)

**Status:** These events relate to context management, not user-facing
workflows. Validation/telemetry use cases may not target them.

**Recommendation:** Include in schema for completeness; no priority for consumer
work.

---

## Part 8: Proposed Nix Option Architecture (Sketch)

### Shared Hook Events Type (lib/ai/ai-common.nix extension)

```nix
# Baseline hook event type — consumed by both Claude and Kiro factories
hookeventModule = { name, ... }: lib.types.submodule {
  options = {
    trigger = lib.mkOption {
      type = lib.types.str;  # soft enum: exact event name
      description = "Hook event trigger (e.g., SessionStart, Stop, PreToolUse).";
    };
    matcher = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional glob pattern (tool names, agent types, server names).";
    };
    enabled = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable/disable this hook without removing it.";
    };
    timeout = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      description = "Command timeout in seconds (hook-specific, not global).";
    };
    # Handler type varies by CLI (Claude: shell | http | prompt | agent; Kiro: command | agent)
    # Defer to per-CLI factory.
  };
};
```

### Claude-Specific Hook Type (packages/claude-code/lib/mkClaude.nix extension)

```nix
# Claude supports four handler types; Kiro supports two
claudeHookModule = lib.types.submodule {
  options = {
    trigger = lib.mkOption {
      type = lib.types.enum [
        "SessionStart" "SessionEnd" "Setup"
        "UserPromptSubmit" "UserPromptExpansion"
        "PreToolUse" "PostToolUse" "PostToolUseFailure" "PostToolBatch"
        "PermissionRequest" "PermissionDenied"
        "Stop" "StopFailure"
        "SubagentStart" "SubagentStop"
        "TaskCreated" "TaskCompleted"
        "PreCompact" "PostCompact"
        "InstructionsLoaded"
        "FileChanged" "CwdChanged" "ConfigChange"
        "WorktreeCreate" "WorktreeRemove"
        "Notification" "MessageDisplay"
        "Elicitation" "ElicitationResult"
        "TeammateIdle"
      ];
      description = "Claude hook event type.";
    };
    matcher = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Tool name, agent type, or file pattern (event-specific).";
    };
    handler = lib.mkOption {
      type = lib.types.submodule {
        options = {
          type = lib.mkOption {
            type = lib.types.enum ["command" "http" "prompt" "agent"];
            description = "Handler type.";
          };
          command = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Shell command (for type=command).";
          };
          # http, prompt, agent options deferred
        };
      };
      description = "Handler specification.";
    };
    # HM-only: capabilities list and input/output schema hints (docs only)
  };
};
```

### Kiro-Specific Hook Type (packages/kiro-cli/lib/mkKiro.nix extension)

```nix
kiroHookModule = lib.types.submodule {
  options = {
    trigger = lib.mkOption {
      type = lib.types.enum [
        "SessionStart" "Stop" "PreToolUse" "PostToolUse"
        "PreTaskExec" "PostTaskExec"
        "UserPromptSubmit"
        "PostFileCreate" "PostFileSave" "PostFileDelete"
        "Manual"
      ];
      description = "Kiro v3 hook trigger.";
    };
    matcher = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional glob pattern (e.g., tool names for PreToolUse).";
    };
    action = lib.mkOption {
      type = lib.types.submodule {
        options = {
          type = lib.mkOption {
            type = lib.types.enum ["command" "agent"];
            description = "Action type (v3 does NOT support prompt type).";
          };
          command = lib.mkOption {
            type = lib.types.nullOr (lib.types.either lib.types.str lib.types.path);
            default = null;
            description = "Command path (for type=command).";
          };
          # prompt field omitted; not supported in v3
        };
      };
      description = "Hook action.";
    };
  };
};
```

### HM/Devenv Projection

**Claude:**

```nix
ai.claude.hooks = lib.types.attrsOf claudeHookModule;
# Emit logic:
# - Shell script → ~/.claude/hooks/<name>
# - HTTP endpoint → settings.json entry (webhook registry)
# - Prompt/agent → settings.json entry
```

**Kiro:**

```nix
ai.kiro.hooks = lib.types.attrsOf kiroHookModule;  # (or envelope type containing array)
# Emit logic:
# - Command → .kiro/hooks/<name>.json (v3 requires real file in devenv)
# - Agent → .kiro/hooks/<name>.json
```

---

## Part 9: Verification & Testing Strategy

### Flake Check Coverage (Static)

**Module evaluation checks** (extend `checks/module-eval.nix`):

1. **Typed schema validation:** Eval `ai.claude.hooks` and `ai.kiro.hooks` with
   valid/invalid inputs; assert errors on type mismatch.
2. **Trigger enum coverage:** Assert that all 30 Claude events are reachable via
   the enum.
3. **Matcher validation:** Test glob patterns and regex where supported.
4. **Emission shape:** Eval HM and devenv projections; assert correct file paths
   and JSON structure.
5. **Collisions:** Assert no duplicate hook names across `ai.hooks` and
   `ai.claude.hooks` (if unified).

**Examples:**

- `ai.claude.hooks.my-hook.trigger = "InvalidEvent"` → type mismatch, fails eval
- `ai.kiro.hooks.bad.matcher = 123` → not a string, fails eval
- Kiro v3 with devenv: assert hook files are REAL (not symlinks), check
  `ls -l .kiro/hooks/`

### Stub-Based Integration Tests

**Extend `checks/validate-at-stop.nix` pattern:**

For each hook type (Claude + Kiro):

1. Write a stub "handler" (shell script or agent) that reads stdin JSON,
   validates fields, outputs mock response
2. Feed test payloads (valid input, malformed input, edge cases)
3. Assert:
   - Exit codes correct (0 for success, 2 for blocking error)
   - Output JSON parseable (if applicable)
   - Declared capabilities honored (e.g., PreToolUse with
     `permissionDecision: "deny"` actually blocks)

**Fixtures:** Organize under `checks/fixtures/hooks/` by CLI and event type:

```
checks/
  fixtures/
    hooks/
      claude/
        SessionStart-input.json
        SessionStart-output-allowed.json
        SessionStart-output-blocked.json
      kiro/
        Stop-input.json
        Stop-output.json
```

### Manual CLI Verification (Future, Expensive)

**Gate:** Only run on breaking schema changes or new consumer (telemetry,
auto-memory) integration.

**Approach:**

1. Spin up isolated sandbox with claude-code / kiro CLI
2. Inject typed hooks from nix-agentic-tools config
3. Trigger each event type (e.g., SessionStart via `claude` or `kiro chat`)
4. Capture hook invocation logs
5. Assert:
   - Hook fired at the right time
   - Input JSON matched expected schema
   - Output processed correctly (if hook returned decision/modification)

**Tool:** Similar to `dev/scripts/kiro-memory-hitl.sh` (throwaway trusted-TUI
project)

---

## Part 10: Recommendations for the Principal Engineer

### Immediate Actions (This Sprint)

1. **Approve scope phasing:** Confirm Phase 1 (schema design), Phase 2 (static
   checks), Phase 3 (integration tests) can proceed; defer Phases 4-5 to
   consumers.

2. **Resolve 8 decisions:**
   - Envelope vs. per-event hooks (recommend: envelope)
   - Matcher type (recommend: glob with regex escape)
   - Backward compatibility strategy (recommend: union type on same option name)
   - Scope deferred items: prompt-based hooks, v2 compat, agent/skill scoping,
     TUI mode

3. **Commission Phase 1 work:**
   - Design Nix option submodules (Claude + Kiro)
   - Draft input/output JSON schemas for each event type
   - Plan code generation or doc extraction to keep schemas DRY

### Downstream Consumers (Post-Phase 1)

- **Telemetry system:** Consume typed hooks to emit metrics when hooks fire
  (event type, trigger, execution time, exit code)
- **Auto-memory v2:** Use typed hooks to validate that memory distiller (Stop
  hook) is correctly wired and meets the schema
- **Workflow optimization:** Analyze hook patterns to recommend turn-reduction
  strategies

### Open Questions for Clarification

1. **Prompt-based hooks:** Are these production-ready in Claude Code? Do they
   work in all surfaces (Terminal, VS Code, Desktop, Web)? What's the token cost
   model?
2. **Kiro v2 lifesupport:** Is v2 still supported, or is v3 the only forward
   path? If v2 is deprecated, should typed schema target v3 only?
3. **Hook scoping:** Can hooks be scoped to specific agents, skills, or MCP
   servers? Or are they always global to the CLI?
4. **TUI vs. headless:** Do hooks fire the same way in TUI mode vs. headless
   (API) mode?
5. **Subagent hooks:** Do subagents inherit parent session's hooks, or can they
   have independent hooks?

---

## Summary Table: Hook Events by Cadence & Capability

| Cadence          | Event               | Input Type | Can Block? | Can Modify? | Can Inject? |
| ---------------- | ------------------- | ---------- | ---------- | ----------- | ----------- |
| **Per-session**  | SessionStart        | Metadata   | ❌         | ❌          | ✅          |
|                  | SessionEnd          | Metadata   | ❌         | ❌          | ❌          |
|                  | Setup               | Metadata   | ❌         | ❌          | ✅          |
| **Per-turn**     | UserPromptSubmit    | Full       | ✅         | ❌          | ✅          |
|                  | UserPromptExpansion | Full       | ✅         | ❌          | ✅          |
|                  | Stop                | Full       | ✅         | ❌          | ✅          |
|                  | StopFailure         | Error      | ❌         | ❌          | ❌          |
| **Per-tool**     | PreToolUse          | Full       | ✅         | ✅          | ✅          |
|                  | PostToolUse         | Full       | ✅         | ✅          | ✅          |
|                  | PostToolUseFailure  | Full       | ✅         | ✅          | ✅          |
|                  | PostToolBatch       | Batch      | ✅         | ❌          | ❌          |
|                  | PermissionRequest   | Full       | ✅         | ✅          | ✅          |
|                  | PermissionDenied    | Metadata   | ✅         | ❌          | ❌          |
| **Sub-tasks**    | SubagentStart       | Metadata   | ❌         | ❌          | ✅          |
|                  | SubagentStop        | Full       | ✅         | ❌          | ✅          |
|                  | TaskCreated         | Metadata   | ✅         | ❌          | ❌          |
|                  | TaskCompleted       | Metadata   | ✅         | ❌          | ❌          |
| **Context**      | PreCompact          | Metadata   | ✅         | ❌          | ✅          |
|                  | PostCompact         | Metadata   | ❌         | ❌          | ❌          |
|                  | InstructionsLoaded  | Metadata   | ❌         | ❌          | ❌          |
| **Environment**  | FileChanged         | Metadata   | ❌         | ❌          | ❌          |
|                  | CwdChanged          | Metadata   | ❌         | ❌          | ❌          |
|                  | ConfigChange        | Metadata   | ✅         | ❌          | ✅          |
| **Worktree**     | WorktreeCreate      | Metadata   | ✅         | ❌          | ❌          |
|                  | WorktreeRemove      | Metadata   | ❌         | ❌          | ❌          |
| **Notification** | Notification        | Metadata   | ❌         | ❌          | ❌          |
|                  | MessageDisplay      | Metadata   | ❌         | ✅          | ❌          |
| **MCP**          | Elicitation         | Metadata   | ✅         | ✅          | ❌          |
|                  | ElicitationResult   | Metadata   | ✅         | ✅          | ❌          |
| **Teammate**     | TeammateIdle        | Metadata   | ✅         | ❌          | ❌          |

---

## Conclusion

The nix-agentic-tools factory currently ships **untyped hook options** that
accept raw script/JSON bodies with no schema validation, matcher support, or
capability hints. This works for handwritten configurations but blocks automated
tooling (telemetry, memory systems, workflow optimization) that needs to reason
about hook behavior.

A **per-event typed schema** (Phase 1-3 work) would:

1. **Enforce correctness:** No malformed JSON, invalid event names, or
   unsupported matchers.
2. **Guide users:** Option descriptions explain input/output contracts, exit
   codes, capabilities.
3. **Enable automation:** Telemetry and memory systems can introspect hook
   config to decide what to track or inject.
4. **Maintain compatibility:** Legacy untyped hooks (raw scripts) continue to
   work via union types.

The factory is well-positioned to implement this: it already wraps upstream's
freeform options (Claude's settings.json, Kiro's .json files) and provides the
transformation layer. Typed options land in the factory; emission logic renders
to the untyped shapes upstream expects.

**Estimated scope:** Phase 1 (design) = 1-2 days; Phase 2-3 (checks + tests) =
3-5 days. Phases 4-5 (consumer integration) = dependent on consumer features.
