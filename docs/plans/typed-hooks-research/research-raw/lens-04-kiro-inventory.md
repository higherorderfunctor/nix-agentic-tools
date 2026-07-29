# Kiro CLI Hooks — Complete v3 Inventory, v2 Stub Surface, and the Nix Typing Design

## Scope of this section

This is the **Kiro CLI hooks** lens of the shared "type every hook as a Nix
option" assessment. It delivers: (1) the complete Kiro v3 hook-trigger inventory
with per-trigger firing, matcher, stdin, action, and blocking semantics; (2) the
discovery/edge-case rules that constrain delivery (workspace-local, global as of
2.13.0, store-symlink skip); (3) the `action: agent` hook type; (4) a deferred
v2 stub surface; (5) the concrete Nix typed-option design that replaces today's
untyped JSON passthrough; and (6) a bounded cross-reference to the Claude Code
hook surface (which a sibling section should own) because it materially changes
the "type _every_ hook" scope decision.

**Confirmed environment fact:** the repo pins `kiro-cli` at **2.13.0**
(`overlays/kiro-cli-sources.json`). This is load-bearing — 2.13.0 is the exact
release (2026-07-17 CLI changelog) that added **global** `~/.kiro/hooks/`
discovery, which invalidates part of the in-repo auto-memory finding (see §4).

---

## 1. The v3 hook trigger inventory (CONFIRMED complete)

Source: official `https://kiro.dev/docs/cli/v3/hooks/` (fetched live) and the
mirrored `docs/plans/kiro-v3-docs.txt:339-353`. The 11 triggers the parent lens
listed are the **complete** set — the docs enumerate exactly these, no more:

| Trigger            | Fires when                                                        | Matcher evaluates against    | Can block? |
| ------------------ | ----------------------------------------------------------------- | ---------------------------- | :--------: |
| `SessionStart`     | Session begins (also resume)                                      | not evaluated — always fires |     No     |
| `Stop`             | "Session ends" per docs — **but empirically per-turn** (see note) | not evaluated                |     No     |
| `PreToolUse`       | Before a tool executes                                            | tool name (regex)            |  **Yes**   |
| `PostToolUse`      | After a tool executes                                             | tool name (regex)            |     No     |
| `PreTaskExec`      | Before a spec task starts                                         | not evaluated                |  **Yes**   |
| `PostTaskExec`     | After a spec task finishes                                        | not evaluated                |     No     |
| `UserPromptSubmit` | User submits a prompt                                             | prompt text (regex)          |  **Yes**   |
| `PostFileCreate`   | After a file is created                                           | file path (regex)            |     No     |
| `PostFileSave`     | After a file is saved                                             | file path (regex)            |     No     |
| `PostFileDelete`   | After a file is deleted                                           | file path (regex)            |     No     |
| `Manual`           | User-triggered on demand (e.g. `/remember`)                       | not evaluated                |     No     |

**New in 3.0** (no v2 equivalent): `PreTaskExec`, `PostTaskExec`,
`PostFileDelete`, `Manual`. The rest are PascalCase renames of v2 triggers
(`agentSpawn→SessionStart`, `userPromptSubmit→UserPromptSubmit`,
`preToolUse→PreToolUse`, `postToolUse→PostToolUse`, `fileEdited→PostFileSave`,
`fileCreated→PostFileCreate`, `stop→Stop`) —
`docs/plans/kiro-v3-docs.txt:357-367`.

**Load-bearing correction to the docs — `Stop` fires PER TURN, not at session
end.** The docs label `Stop` "Session ends", but the in-repo auto-memory work
empirically established that `Stop` fires **on every turn hand-back** and there
is **no `SessionEnd`** trigger at all (`packages/kiro-cli/lib/autoMemory.nix`
header; the `claude-rules-kiro-cli.md` fragment "The two-problem frame": _"v3
has no `SessionEnd`/on-exit hook — `Stop` fires per turn"_). Any
telemetry/memory consumer must treat `Stop` as per-turn and debounce; there is
no on-exit hook.

---

## 2. The stdin / action / output contracts

### 2a. stdin schema — metadata-only (docs are SILENT; empirical fills the gap)

The official docs say only _"Receives hook context as JSON on stdin"_ and **do
not enumerate the fields** (confirmed by fetching the live page — it omits the
schema). The field set is an **empirical in-repo finding**: command hooks
receive **metadata only**, `{session_id, cwd, ...}` plus `hook_event_name` —
there is no transcript, no tool input, no prompt text delivered. Critically:

- `UserPromptSubmit`'s `prompt` field is **empty** on stdin (the auto-memory
  recall hook must seed its archive query from `now.md`, not from the prompt —
  `claude-rules-kiro-cli.md`, D12; validated in
  `checks/validate-at-stop.nix`-style payloads elsewhere).
- The write-side memory hook reads the transcript **off disk itself**
  (`~/.kiro/sessions/<hash>/<sid>/messages.jsonl`) precisely because stdin
  carries no conversation content.

This is a **sharp contrast with Claude Code**, whose stdin carries
`session_id, transcript_path, cwd, permission_mode, tool_input, tool_response`,
etc. (§7). A typed telemetry/memory consumer built on Kiro hooks cannot assume
rich stdin.

### 2b. action schema — two types

```json
"action": { "type": "command", "command": "<shell command>" }   // subprocess, stdin=metadata JSON
"action": { "type": "agent",   "prompt":  "<steering text>" }    // NO subprocess; prompt appended to model context
```

- **`command`**: spawns a subprocess, receives the metadata JSON on stdin, exit
  code governs behavior. Honors `timeout` (default **60s**, `0` disables).
- **`agent`**: appends the `prompt` string to the model context. **No subprocess
  spawned.** `timeout` is **ignored** for agent actions. Use for lightweight
  steering/guardrails (docs: _"appends a prompt string to the model context… Use
  for lightweight steering and guardrails"_). This is the "hook that dispatches
  a prompt" type the lens asked about — it is _not_ a subagent dispatch; it is
  inline prompt injection into the current agent's context.

### 2c. Hook fields (per-hook object)

| Field         | Type          | Required | Default                                    |
| ------------- | ------------- | -------- | ------------------------------------------ |
| `name`        | string        | Yes      | — (shown in telemetry)                     |
| `description` | string        | No       | —                                          |
| `trigger`     | string        | Yes      | —                                          |
| `matcher`     | regex string  | No       | always-match                               |
| `action`      | object        | Yes      | —                                          |
| `timeout`     | int (seconds) | No       | **60** (`0` disables; ignored for `agent`) |
| `enabled`     | bool          | No       | **true**                                   |

### 2d. Output / blocking contract (command actions)

| Exit code | Behavior                                                                                                               |
| --------- | ---------------------------------------------------------------------------------------------------------------------- |
| `0`       | Success. **STDOUT is added to context for `SessionStart` and `UserPromptSubmit` only**; ignored for all other triggers |
| `2`       | **Block** — only for `PreToolUse` and `UserPromptSubmit`. STDERR is returned to the LLM                                |
| other     | Warning shown to user; execution proceeds                                                                              |

Key asymmetries vs Claude: (a) blocking is **exit-code only** (`2`), there is
**no JSON `{"decision":"block"}` channel** — a Kiro hook cannot emit structured
decision JSON the way the repo's `validate-at-stop` Claude hook does; (b) STDOUT
injection is limited to two triggers; (c) `Stop`/`PostTaskExec` etc. **cannot
block** and their stdout is discarded, so a `Stop` hook can do side-effects only
(exactly how auto-memory uses it — write to disk, exit 0).

**Under-documented:** the docs mention _"the `${…}` template variable is
available in command actions for file-related triggers"_ but the exact variable
name is mangled in the source (likely `${file}`/an env var like
`$KIRO_FILE_PATH`) — needs empirical confirmation before a typed option
advertises it.

---

## 3. The envelope: many hooks / many triggers per file

Each `.kiro/hooks/<name>.json` is a **`{version:"v1", hooks:[…]}` envelope**
carrying an **array** of hook objects, each with its own `trigger`. One file
therefore fans multiple triggers. This is CONFIRMED live, not just documented:
`packages/kiro-cli/lib/autoMemory.nix:173-201` ships **one** `kiro-memory.json`
envelope with **four** hooks across **four distinct triggers** (`Stop`,
`SessionStart`, `Manual`, `UserPromptSubmit`), and `module-eval.nix:1035-1055`
asserts all four `"trigger":…` strings coexist in the emitted JSON. The
`claude-rules-kiro-cli.md` fragment records D30: _"kiro fires 3+ hooks from one
file live — no per-hook split."_ The typed Nix option must therefore model an
**envelope with a list of typed hooks**, not one-hook-per-file.

---

## 4. Discovery & edge cases (the delivery constraints)

Three independent constraints, of which one **changed in the pinned version**:

1. **Location — workspace-local AND (now) global.** v3 discovers hooks under the
   launch cwd's `.kiro/hooks/`. **As of kiro-cli 2.13.0 (2026-07-17),
   `~/.kiro/hooks/` global hooks also fire in every workspace** (CLI changelog,
   fetched live: _"Hooks placed in `~/.kiro/hooks/` now fire in every workspace
   automatically… Workspace-level hooks continue to work alongside global
   ones"_). The repo pins **2.13.0**, so global hooks are in play **now**. This
   **partially invalidates** the in-repo finding (`claude-rules-kiro-cli.md`:
   _"never global `~/.kiro/hooks/` (v3 skips both)"_ and memory
   `project_kiro_v3_hooks_workspace_local`) — that finding predates 2.13.0.
   Historical issues:
   [kirodotdev/Kiro #5440](https://github.com/kirodotdev/Kiro/issues/5440),
   [#7737](https://github.com/kirodotdev/Kiro/issues/7737),
   [#9075](https://github.com/kirodotdev/Kiro/issues/9075) (global-hooks feature
   requests, now resolved).

2. **Real files, NOT store symlinks.** v3's `read_dir` scan of the hooks
   directory **skips symlinks** — a symlinked hook file never loads and `/hooks`
   shows nothing. This is **independent of location** and, importantly, is
   isolated evidence: the devenv backend proved that a _workspace-local_
   `files.*` **symlink** did NOT load while a _workspace-local_ **real file**
   did (`packages/kiro-cli/lib/mkKiro.nix:643-667` writes real files via
   `enterShell` + `install`/`cp`, with the rationale comment). Because HM's
   `home.file` always produces store symlinks, **HM cannot deliver a working v3
   hook via `home.file`** — even at the now-valid global path. Whether 2.13.0
   changed the symlink-skip behavior is **UNVERIFIED and must be re-tested**
   (see open questions).

3. **Subagents.** The lens says "Kiro reportedly does NOT fire hooks in
   subagents." The **docs claim the opposite**: hooks _"apply across all agents
   in the workspace"_ and the Spec agent _"your permissions, hooks, and MCP
   servers all apply to it the same way"_ (`kiro-v3-docs.txt:75,304`). This is a
   **contradiction to resolve empirically** — likely the distinction is between
   _named agents_ (hooks apply) vs the `subagent` delegation tool's ephemeral
   children (may not). Do not encode a "no subagent hooks" assumption without a
   live test.

---

## 5. V2 hooks — the deferred stub surface

v2 hooks were **embedded inside agent config** (`toolsSettings`/agent JSON),
using **camelCase triggers** (`agentSpawn`, `userPromptSubmit`, `preToolUse`,
`postToolUse`, `fileEdited`, `fileCreated`, `stop`) and regex matchers that
_"transfer directly"_ to v3 (`kiro-v3-docs.txt:357-380`). There was **no
standalone `.kiro/hooks/*.json`** and **no `Manual`/spec-task/`PostFileDelete`**
triggers. The migration path is the built-in **`kiro-cli agent migrate`**, which
auto-converts embedded v2 hooks to the standalone v3 format (docs: _"Run
`kiro-cli agent migrate` to auto-convert them"_; embedded hooks _"still work
during the transition"_).

**Design implication:** v2 needs only a **code stub** — since the repo runs
2.13.0 and the consumer targets v3 (`tui`⇒`--v3`), a typed v2 surface is dead
weight. Leave the existing untyped `ai.kiro.hooks` passthrough as the v2 escape
hatch (a consumer can still hand-author embedded-hook JSON into an agent file
via `ai.kiro.agents`), and document `agent migrate` as the on-ramp. No typed v2
modeling.

---

## 6. THE NIX ANGLE — typed option design

### 6a. Today's state (untyped passthrough)

`packages/kiro-cli/lib/mkKiro.nix:316-327` defines
`ai.kiro.hooks = attrsOf (either lines path)` — **raw JSON passthrough**:
whatever string the consumer authors is written to
`<configDir>/hooks/<name>.json`. The comments at `mkKiro.nix:275-298` already
flag this as GREENFIELD and spell out the exact v3 schema to model typed _"like
`permissions`"_. Delivery split (already correct for hooks): **HM** writes via
`home.file` (`mkKiro.nix:469-471` — but note §4.2: this is a **symlink and does
not actually load under v3**, a latent bug the typed refactor should fix);
**devenv** writes **real files** via `enterShell` (`mkKiro.nix:650-667`). The
working real-world consumer is `autoMemory.nix`, which hand-builds the envelope
with `builtins.toJSON` and relies on the devenv real-file path.

### 6b. The typed option (mirror `permissions`, model the envelope)

`permissions` is the precedent: a `listOf (submodule {...})` with a soft-enum
`capability` (`enum […] // str`) and hard enums for closed sets, rendered via
`pkgs.formats.yaml`. Hooks are one level deeper (envelope → list of hooks →
action), so mirror that as `attrsOf (submodule …)` keyed by envelope filename:

```nix
hooks = lib.mkOption {
  # attr key = envelope filename stem → <configDir>/hooks/<name>.json
  type = lib.types.attrsOf (lib.types.submodule {
    options = {
      version = lib.mkOption { type = lib.types.str; default = "v1"; };
      hooks = lib.mkOption {
        default = [];
        type = lib.types.listOf (lib.types.submodule {
          options = {
            name        = lib.mkOption { type = lib.types.str; };
            description = lib.mkOption { type = lib.types.str; default = ""; };
            trigger = lib.mkOption {
              # soft enum: the 11 v3 triggers autocomplete, any string still accepted
              type = lib.types.either (lib.types.enum [
                "Manual" "PostFileCreate" "PostFileDelete" "PostFileSave"
                "PostTaskExec" "PostToolUse" "PreTaskExec" "PreToolUse"
                "SessionStart" "Stop" "UserPromptSubmit"
              ]) lib.types.str;
            };
            matcher = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
            action = lib.mkOption {
              type = lib.types.submodule {
                options = {
                  type    = lib.mkOption { type = lib.types.enum ["command" "agent"]; };
                  command = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; }; # ABSOLUTE store path (nix-standards)
                  prompt  = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
                };
              };
            };
            timeout = lib.mkOption { type = lib.types.nullOr lib.types.int; default = null; };  # 60 default; 0 disables
            enabled = lib.mkOption { type = lib.types.bool; default = true; };
          };
        });
      };
    };
  });
  default = {};
};
```

Cross-field validation the submodule can't express alone → module `assertions`
(mirroring the existing `agents`/`hooksDir` mutual-exclusion asserts at
`mkKiro.nix:419-429`): (a) `action.type=="command"` ⇒
`command != null && prompt == null`; (b) `action.type=="agent"` ⇒
`prompt != null && command == null`; (c) warn that `timeout` is ignored for
`agent`. Because Kiro's MCP/hook env replaces the process env, `action.command`
**must be an absolute store path** (nix-standards fragment;
`getExe`/`writeShellScript` — exactly what `autoMemory.nix` already does with
`command = "${stopWrapper}"`).

### 6c. Lowering to the file

Render each envelope with `builtins.toJSON`, dropping
null/`enabled==true`/default-`timeout` keys for clean output (reuse
`aiCommon.filterNulls`-style pruning). The rendered string is what
`autoMemory.nix` produces today, so the typed option can **subsume** the
hand-built generator: `autoMemory` becomes a _producer of typed values_ rather
than a JSON-string producer, giving it eval-time type-checking for free.

**Delivery (respect §4.2 real-file constraint):**

- **devenv** — keep the existing `enterShell` real-file copy
  (`install -m 0644 <writeText> .kiro/hooks/<name>.json`). This is the
  proven-working path. Workspace-local.
- **HM** — the current `home.file` symlink route is a latent no-op under v3. Two
  real options: **(i)** a `home.activation` script that **copies** the
  store-rendered JSON to real files under `~/.kiro/hooks/<name>.json` (now that
  2.13.0 makes global hooks load), mirroring the existing `kiroSettingsMerge`
  activation pattern (`mkKiro.nix:544-551`) — this is the only HM path that
  yields real files; or **(ii)** accept **devenv-only** delivery for hooks
  (document HM as unsupported, as `tui`/`permissions` already are HM-only for
  their own reasons). Recommendation: (i) if a live 2.13.0 test confirms global
  real-file hooks load; else (ii).

### 6d. Verification (the "burns tokens" question)

The `validate-at-stop` precedent (`checks/validate-at-stop.nix`) is directly
reusable: feed a **synthetic metadata payload**
(`{"cwd":…,"session_id":…,"hook_event_name":…}`) on stdin to a
**`command`-action** hook wrapper, assert stdout/exit — **hermetic, no live CLI,
no tokens**. Kiro's metadata-only stdin (§2a) makes this _easier_ than Claude
(no transcript to fabricate). So:

- **`command`-action hooks → fully covered by `nix flake check`** (hermetic
  branch tests + a rendered-envelope eval test like
  `module-kiro-auto-memory-hm-emits-hooks`).
- **`agent`-action hooks → CANNOT be hermetically tested** — they inject a
  prompt into a live model context with no subprocess to observe. These need a
  **manual / env-gated** path: a `nix run .#check-kiro-agent-hooks` flake app or
  a `devenv task` that launches an authed `--v3` TUI against a scratch project
  (the `dev/scripts/kiro-memory-hitl.sh` harness is the template). Gate behind
  an env var so `nix flake check` skips it. This split (hermetic for command,
  manual/env-gated for agent + any authed-CLI hook) is the answer to the goal's
  open question: `nix flake check` **can** cover the deterministic majority;
  agent-action and live-injection verification must be a separate opt-in
  app/task.

---

## 7. Cross-reference: Claude Code hook surface (scope-forcing — a sibling section should own the detail)

Fetched live from `https://code.claude.com/docs/en/hooks`. **The Claude surface
is vastly larger and faster-moving than Kiro's** — this materially affects the
goal's "type _every_ hook" ambition:

- **~30 hook events** (not the ~9 the goal implies):
  `SessionStart, Setup, UserPromptSubmit, UserPromptExpansion, PreToolUse, PermissionRequest, PermissionDenied, PostToolUse, PostToolUseFailure, PostToolBatch, Notification, MessageDisplay, SubagentStart, SubagentStop, TaskCreated, TaskCompleted, Stop, StopFailure, TeammateIdle, InstructionsLoaded, ConfigChange, CwdChanged, FileChanged, WorktreeCreate, WorktreeRemove, PreCompact, PostCompact, Elicitation, ElicitationResult, SessionEnd`.
- **5 handler types**, not 1: `command`, `http`, `mcp_tool`, `prompt`, `agent` —
  each with its own field set and default timeout (600 command/http/mcp_tool, 30
  prompt, 60 agent).
- **Rich JSON I/O**: matcher + `if` permission-rule gating,
  `updatedInput`/`updatedToolOutput` mutation, `permissionDecision`
  (`allow/deny/ask/defer`), `additionalContext`, `async`/`asyncRewake`, etc.
- **Config shape**:
  `settings.hooks.<Event>[] = {matcher, hooks:[{type,command,timeout,…}]}` —
  exactly the structure today's `ai.claude.settings.hooks` passthrough carries
  untyped.

**Repo state for Claude** (`packages/claude-code/lib/mkClaude.nix:250-281`):
`ai.claude.hooks = attrsOf lines` are **script bodies** routed 1:1 to the
**nixpkgs** `programs.claude-code.hooks` option — which I confirmed is
`attrsOf lines` writing files under `configDir/hooks/` (nixpkgs module
`modules/programs/claude-code.nix:305-313`). The **event wiring** lives entirely
in the **untyped** `settings.hooks` freeform passthrough (HM: upstream writes it
into settings.json; devenv: `mkClaude.nix:505-508` merges
`settings.hooks // cfg.hooks` into `claude.code.hooks`). So the Claude
typed-hook work is a **separate, larger effort**: type the `settings.hooks`
event map (30 events × 5 handler types) while leaving `ai.claude.hooks` as the
script-body file writer the wiring references.

**Scope decision this forces (for the principal):** typing _"every"_ Claude
event is a moving target that will drift every release (the reference already
carries version-gated fields like `prompt_id` v2.1.196+,
`$CLAUDE_CODE_BRIDGE_SESSION_ID` v2.1.199+). Kiro's 11 triggers are bounded and
stable — a clean, finishable typed surface. Recommend: **fully type Kiro v3 now;
for Claude, type a curated core**
(`PreToolUse, PostToolUse, UserPromptSubmit, Stop, SubagentStop, SessionStart, SessionEnd, PreCompact`)
with soft-enum event names + freeform passthrough for the long tail, rather than
chasing all 30.

---

## 8. Composition & precedence (for the design phase)

- **Kiro:** hooks are files, not merged maps — precedence is filesystem:
  **global `~/.kiro/hooks/` + workspace `.kiro/hooks/` both load and coexist**
  (2.13.0). Two envelopes with the same `<name>.json` at different scopes → both
  load (no dedup documented); two hooks with the same `name` inside one envelope
  → undefined, avoid. The Nix option is `attrsOf` keyed by filename, so the
  module system already forces unique filenames within one backend;
  **cross-scope (HM-global vs devenv-workspace) collisions are NOT caught** by
  Nix and would double-fire — a real composition hazard to document.
- **Claude:** events **accumulate across settings layers** (user `~/.claude`,
  project `.claude`, local, policy, plugin, skill/agent frontmatter) — arrays
  concatenate, identical handlers dedupe (command+args / http-url). The repo
  already threads two sources (`cfg.hooks` authoritative `//` legacy
  `settings.hooks`, `mkClaude.nix:507`); a typed surface must preserve
  last-writer-wins semantics and the collision-check helper (`ai-common.nix:315`
  `mergeWithCollisionCheck`) is the existing tool for it.

---

## 9. Downstream consumer readiness (telemetry / memory / turn-optimization)

- **Telemetry** — Kiro's `name` field is _"shown in telemetry"_ (docs) and hooks
  fire on well-defined lifecycle points; a typed option makes it trivial to
  auto-inject a telemetry wrapper on `command` actions. `agent` actions emit
  nothing observable (no subprocess) — telemetry can only see them fire, not
  their effect.
- **Memory (auto record/inject)** — already proven end-to-end via
  `autoMemory.nix` (Stop=write, SessionStart=flush, UserPromptSubmit=read,
  Manual=force). The typed option should be designed so `autoMemory` is a
  _reference consumer_ of it, not a parallel hand-rolled path (removes the
  `builtins.toJSON`-string producer, gains type-checking).
- **Turn/tool-call minimization** — `agent`-action hooks (inline steering, no
  subprocess) and `PreToolUse` blocking are the levers; both are expressible in
  the typed schema above. Note Kiro cannot return `updatedInput` (no mutation
  channel, unlike Claude), so turn-shaping on Kiro is limited to block(exit
  2)/steer(agent-prompt).
