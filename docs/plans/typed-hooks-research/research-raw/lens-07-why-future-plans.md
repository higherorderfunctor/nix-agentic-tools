# Typed Hook Options: The "Why", the Three Future Plans, Passthrough Gaps, and the Post-PoC Per-Hook Documentation Contract

## 0. Framing — why this work exists

The typed hook surface is not the deliverable; it is the **substrate three future systems are built on, purely in Nix, with no later code changes**:

1. **Telemetry** — emit a structured event every time a hook fires (turn/tool/latency accounting).
2. **Memory** — auto-record on session/turn boundaries + auto-inject on prompt. There is already a **working, shipped precedent** for this on Kiro: `packages/kiro-cli/lib/autoMemory.nix` proves one hook envelope drives Stop/SessionStart/UserPromptSubmit/Manual and injects recall.
3. **Workflow optimization** — cut wasted turns/tool-calls via PreToolUse gating and additionalContext injection (two concrete in-flight cases: `docs/plans/skill-bootstrap-context-injection.md`, `docs/plans/prek-stop-hook-validator.md`).

Every one of these is a _hook consumer_. The typed option must expose enough of the hook contract (event, matcher, stdin fields it reads, output fields it emits) that each plan can be wired by declaring Nix options — never by hand-authoring `settings.json`/`hooks.json` or writing new factory code. That is the acceptance test for the design below.

---

## 1. Scope reframe (load-bearing): Claude now has ~30 hook events, not 9

The official reference (`https://code.claude.com/docs/en/hooks`, fetched 2026-07-20) enumerates **far more than the classic nine**. Confirmed core events plus a large expansion:

- **Classic / load-bearing:** `PreToolUse`, `PostToolUse`, `UserPromptSubmit`, `Stop`, `SubagentStop`, `SessionStart`, `SessionEnd`, `PreCompact`, `Notification`.
- **Newer, directly useful to the three plans:** `PostToolBatch` (fires once per resolved parallel tool batch before the next model call — the cheapest telemetry/turn-accounting point), `SubagentStart`, `PostCompact`, `StopFailure` (API-error turns), `PostToolUseFailure`, `PermissionRequest`/`PermissionDenied`, `UserPromptExpansion` (slash-command/skill expansion), `InstructionsLoaded`, `ConfigChange`, `CwdChanged`, `FileChanged`, `TaskCreated`/`TaskCompleted`, `Setup`, `MessageDisplay`, `Elicitation`/`ElicitationResult`, `WorktreeCreate`/`WorktreeRemove`, `TeammateIdle`.

**Caveat on confidence:** the event _list_ and the blocking/exit contract for the core events are high-confidence. Some exotic events and exact stdout field names (`updatedInput`, `updatedToolOutput`, `permissionDecision:"defer"`, `displayContent`, `reloadSkills`) came through a summarizer and **must be re-verified against the live doc during the hardening pass** before being typed. This reframe matters for phasing: "type every Claude hook" is a ~30-event commitment, so the PoC must pick a subset and freeform-passthrough must survive as the escape hatch for the long tail.

Kiro v3 is a **fixed 11-trigger** surface (`docs/plans/kiro-v3-docs.txt:339-353`): `SessionStart, Stop, PreToolUse, PostToolUse, PreTaskExec, PostTaskExec, UserPromptSubmit, PostFileCreate, PostFileSave, PostFileDelete, Manual`. Much smaller, fully closed, and already partially exercised by autoMemory.

---

## 2. Current typed surface (the baseline we are replacing)

| Surface                    | Option                                        | Type today                                               | What it actually controls                                                    | Gap                                                                        |
| -------------------------- | --------------------------------------------- | -------------------------------------------------------- | ---------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| Claude bodies              | `ai.claude.hooks` (`mkClaude.nix:250-267`)    | `attrsOf lines`                                          | Writes **script bodies** to `~/.claude/hooks/<name>`                         | Not event-wiring; no matcher, no event                                     |
| Claude bodies dir          | `ai.claude.hooksDir` (`mkClaude.nix:268-281`) | `nullOr dirOptionType`                                   | Dir of body files                                                            | same                                                                       |
| Claude **wiring (HM)**     | `ai.claude.settings.hooks`                    | **freeform JSON** (submodule `freeformType`)             | The real `{PreToolUse:[{matcher,hooks:[...]}]}` event map in `settings.json` | **Untyped passthrough**                                                    |
| Claude **wiring (devenv)** | upstream `claude.code.hooks.<name>`           | typed submodule `{enable,name,hookType,command,matcher}` | Upstream cachix/devenv integration                                           | **Different shape than HM → no parity**                                    |
| Kiro                       | `ai.kiro.hooks` (`mkKiro.nix:316-320`)        | `attrsOf (either lines path)`                            | **raw JSON** to `<configDir>/hooks/<name>.json`                              | **Untyped passthrough**; v3 schema only in comments (`mkKiro.nix:292-298`) |
| Kiro dir                   | `ai.kiro.hooksDir` (`mkKiro.nix:323-327`)     | `nullOr path`                                            | dir of JSON                                                                  | same                                                                       |

**Confirmed schema-mismatch bug** (`mkClaude.nix:507`): the devenv projection does `hooks = (cfg.settings.hooks or {}) // cfg.hooks;` — it merges the **settings.json event-map shape** (`{PreToolUse=[…]}`) with the **script-body attrs** (`{pre-edit = "#!/usr/bin/env bash…"}`) into ONE `claude.code.hooks` option that upstream models as named `hookType` submodules. Two incompatible shapes, `//`-merged. `checks/module-eval.nix:700-714` locks in the `settings.hooks → upstream` route but does not catch the shape collision. This is the strongest single argument for typing.

---

## 3. Future plan → hook mapping

### 3a. Telemetry (fire-and-forget)

**Events/triggers.** The point is to fire on _boundaries_ and _actions_:

| CLI    | Events                                                                                                                                                                                                                                                                                  | Why                                            |
| ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------- |
| Claude | `PostToolBatch` (primary — one event per parallel batch), `PostToolUse` (per-tool granularity), `Stop` (per-turn), `UserPromptSubmit` (per-prompt), `SessionStart`/`SessionEnd` (session bounds), `StopFailure` (API-error turns), `SubagentStart`/`SubagentStop` (subagent accounting) | Turn, tool-call, latency, and failure counters |
| Kiro   | `Stop` (**fires per-turn on Kiro** — convenient turn counter), `PostToolUse`, `SessionStart`, `UserPromptSubmit`                                                                                                                                                                        | Same, minus SessionEnd (Kiro has none)         |

**Stdin fields depended on.** Claude: `session_id`, `prompt_id` (turn correlation), `hook_event_name`, `tool_name`, `tool_input`, `tool_response`, `effort.level`, `cwd`; for batch `tool_calls[]`; for Stop `stop_hook_active`, `last_assistant_message`. Wall-clock timestamps are **not in stdin** — the wrapper stamps its own. Kiro: **`session_id` + `cwd` ONLY** — stdin is metadata-only (`claude-rules-kiro-cli.md`, D12/D23), so Kiro per-tool telemetry payloads are thin unless the v3 PostToolUse stdin turns out to carry `tool_name` (open question §7).

**Output fields depended on.** **None.** Telemetry is the cleanest plan: exit 0, no stdout, no block, no inject. It therefore works on _every_ event including non-blocking ones, and can run async (background the write) to add zero turn latency — unlike autoMemory, which deliberately chose synchronous (D8/D27) because it writes into the model's context.

**Typed option must expose:**

- Per-event, matcher-aware attachment of a wrapper command (the wiring gap).
- **List semantics per event** — telemetry must coexist with validate-at-stop and memory on the same `Stop`. The typed option must be an append-list, not a single command.
- A reusable `mkTelemetryHooks` builder (mirroring `kiroAutoMemory`): inputs = sink (file/socket/OTLP endpoint via env), captured-field allowlist (redaction), async vs sync, per-event enable. Absolute store paths; sink credentials via runtime-`cat` (SOPS pattern, `autoMemory.nix:104-109`) never baked.

### 3b. Memory (generalize `autoMemory.nix`)

The precedent already maps the write/read split cleanly; generalize it to Claude and promote it into the typed surface.

| Role           | Kiro (shipped)                                                                                                         | Claude (to build)                                                                                                                                                                                             | Key divergence                                                                                                                                             |
| -------------- | ---------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| WRITE / record | `Stop` (per-turn distill), `SessionStart` (flush prior tails), `Manual` (`/remember` force) — `autoMemory.nix:173-201` | `Stop` (per-turn), `SessionEnd` (clean end-of-session flush **Claude can do, Kiro cannot** — no SessionEnd on v3), `SessionStart` (`source=resume`), optionally `PreCompact` (capture pre-compaction context) | Claude stdin gives **`transcript_path`** directly; Kiro does **not** → Kiro must glob-locate its transcript itself                                         |
| READ / inject  | `UserPromptSubmit` → recall (`autoMemory.nix:194-199`)                                                                 | `UserPromptSubmit` → `additionalContext`, or `SessionStart` → `additionalContext`                                                                                                                             | Claude `UserPromptSubmit` **carries `prompt`** → can query-on-prompt; Kiro's `prompt` field is **empty** (D12) → seeds archive query from `now.md` instead |

**Output fields depended on.** WRITE: none (exit 0, inject nothing). READ/inject: Claude uses structured `hookSpecificOutput.additionalContext` (Stop/PostToolUse) or top-level `additionalContext` (UserPromptSubmit/SessionStart); Kiro injects via **raw stdout on exit 0** (docs: "STDOUT added to context (SessionStart, UserPromptSubmit)"). The typed builder must emit **both output conventions** from one declaration.

**Typed option must expose:**

- A generalized `lib.ai.apps.mkAutoMemory { cli, … }` returning `{ hooks; rules; }` values for the target CLI's typed hook + rule options (Kiro version already does exactly this — `autoMemory.nix:231-238`).
- The **`Manual` trigger** and **`additionalContext` injection** must be first-class in the schema (they are the two things script-body `ai.claude.hooks` cannot express today → memory-on-Claude currently _forces_ the untyped `settings.hooks` route).
- Carry forward `home` baking (load-bearing, D25/`autoMemory.nix:85-93`), `env`, `omEnv`, `omPgPasswordFile` runtime-cat secret, `timeout`.

### 3c. Workflow optimization (minimize turns & tool-calls)

| CLI    | Events                                                                     | Mechanism                                                                                                                                      |
| ------ | -------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| Claude | `PreToolUse` (matcher on `tool_name`)                                      | Gate: `hookSpecificOutput.permissionDecision` = deny/ask + `permissionDecisionReason`; or **rewrite** via `updatedInput` (avoids a round-trip) |
| Claude | `PostToolUse` (matcher `^Skill$`, branch on `tool_input.skill`)            | Inject resolved bootstrap set as `additionalContext` — the skill-bootstrap case, collapses 3-4 read turns to 0                                 |
| Claude | `UserPromptSubmit` / `SessionStart`                                        | Front-load `additionalContext`                                                                                                                 |
| Claude | `Stop` / `PostToolBatch`                                                   | `decision:"block"` + `reason` to force a fix pass / interrupt the loop (validate-at-stop, **already shipped**)                                 |
| Kiro   | `PreToolUse`, `UserPromptSubmit` (both **can block**: exit 2 + STDERR→LLM) | Gate                                                                                                                                           |
| Kiro   | any trigger, **`action:{type:"agent",prompt}`**                            | Native no-subprocess steering — a turn-min primitive with no shell hook                                                                        |

**Stdin depended on:** `tool_name`, `tool_input` (esp. `tool_input.skill` — **field name UNVERIFIED**, must dump a live payload, per `skill-bootstrap-context-injection.md:50-59`), `prompt` (Claude), `stop_hook_active` (loop guard).

**Output depended on:** `hookSpecificOutput.additionalContext`, `permissionDecision`+`permissionDecisionReason`, `updatedInput`, `decision:"block"`+`reason`. Kiro: exit-2+stderr, stdout-on-0, `agent` action.

**Typed option must expose:** per-event matcher-aware wiring; the output envelope modeled as helper builders (`mkInjectContext`, `mkBlockWithReason`, `mkGate`) so a Nix consumer gets a correct JSON envelope for free instead of re-hand-rolling it (DRY) and instead of silently no-op'ing on malformed JSON.

---

## 4. Passthrough gaps blocking migration off `programs.*` / `settings.hooks`

1. **No typed event-wiring on Claude at all.** The event→matcher→command map lives only in freeform `ai.claude.settings.hooks` (HM) and a _different_ upstream `claude.code.hooks` submodule (devenv). Migrating a Stop hook today means freeform on HM, typed `hookType` on devenv → no single surface, no parity.
2. **Body-vs-wiring split is unlinked.** `ai.claude.hooks` writes a body file; you must _separately_ reference `~/.claude/hooks/<name>` inside `settings.hooks`. And the two are `//`-merged into one incompatible option (§2 bug). A typed option should let you declare the command once and get body + wiring together.
3. **Output contract is invisible to the type system.** `additionalContext` / `decision:block` / `permissionDecision` / `updatedInput` are hand-authored JSON inside scripts. Memory-inject (3b) and turn-min gating (3c) both need them; without typing, every consumer re-implements the envelope and malformed JSON silently no-ops.
4. **Kiro `ai.kiro.hooks` is raw JSON.** No validation that `trigger` is a real PascalCase v3 trigger (a v2 lowercase `stop` silently never fires), no modeling of the two action types (`command` vs `agent`), no matcher-semantics guard. The code comments already say to model it typed like `permissions` (`mkKiro.nix:277-298`).
5. **Composition/precedence unmodeled.** Multiple contributors target one event (top-level pool + per-CLI + memory helper + telemetry helper all on `Stop`). Hooks need **list-append coexistence** (with optional dedup), which is the _opposite_ of the `mergeWithCollisionCheck` collision-as-failure policy used for rules/skills. There is no hook merge policy today.
6. **No absolute-store-path enforcement on the command.** The command is a freeform string; nothing enforces the nix-standards absolute-path rule that Claude/Kiro MCP env-replacement makes load-bearing (`claude-rules-nix-standards.md`). A typed option could require a package/`getExe` instead of a bare string.
7. **Kiro edge cases unmodeled:** hooks do **not** fire in subagents (telemetry/memory blind spot); v3 hooks must be **real workspace files** (`read_dir` skips store symlinks; HM global `~/.kiro/hooks/` is ignored → HM `ai.kiro.hooks` is effectively dead for v3, `claude-rules-kiro-cli.md`). The typed option should encode devenv real-file `enterShell` delivery (`mkKiro.nix:650-658`) as the Kiro default and warn on HM-global-for-v3.
8. **Matcher semantics differ per event and per CLI.** Claude matchers match `tool_name` (PreToolUse), `notification_type`, `source` (SessionStart), or file globs with a special `|`-only syntax (FileChanged); Kiro matchers match tool name / file path / prompt text by trigger and are **not evaluated** for SessionStart/Stop/Manual. Only a typed schema can validate/document per-event matcher meaning.

---

## 5. Per-hook documentation contract (the post-PoC template)

Fill this for **every event × CLI** during the hardening pass:

```
event:            <name>
cli:              claude | kiro-v3 | kiro-v2(stub)
fires-when:       <precise trigger condition>
matcher:          supported? → matches-against (tool_name | file-path | prompt | source | none)
stdin-schema:     common {session_id, cwd, hook_event_name, transcript_path?} + event-specific {…}
stdout/exit:      exit 0 → …; exit 2 → …; other → …; honored stdout JSON fields {…}
blocking?:        yes/no + mechanism
inject?:          additionalContext (structured) | raw-stdout-to-context | none
failure-handling: timeout=<s> → <behavior>; nonzero-non-2 exit → <behavior>; malformed JSON → <behavior>
test-tier:        T1 hermetic-stub | T2 eval-materialization | T3 env-gated-live(tokens)
edge-cases:       subagent-fire? | TUI-vs-headless | workspace-local | effort.level-present?
```

### Filled example 1 — Claude `Stop` (touched by all three plans; matches the validate-at-stop precedent)

```
event:            Stop
cli:              claude
fires-when:       Claude finishes responding (end of a turn / hand-back)
matcher:          none — always fires
stdin-schema:     {session_id, prompt_id, transcript_path, cwd, permission_mode,
                   effort:{level}, hook_event_name:"Stop", last_assistant_message,
                   stop_hook_active}
stdout/exit:      exit 0 → JSON processed; exit 2 → prevents stop, STDERR→model, turn continues;
                   other → non-blocking error, STDERR in transcript
                   honored stdout: decision:"block"+reason, hookSpecificOutput.additionalContext,
                   systemMessage, suppressOutput, continue
blocking?:        yes (exit 2 or decision:"block") — forces continuation
inject?:          additionalContext (non-error feedback; conversation continues)
failure-handling: timeout=600s → hook killed, treated as non-blocking; nonzero-non-2 → STDERR to
                   transcript, stop proceeds; malformed JSON on stdout → ignored, stop proceeds
test-tier:        T1 (validate-at-stop.nix already does this: synthetic payload → assert stdout/exit),
                   T2 (settings.json render), T3 (headless `claude -p`, POC-proven, tokens)
edge-cases:       stop_hook_active guards infinite-loop (must short-circuit when "True");
                   distinct from SubagentStop (subagent hand-back); effort.level present
```

### Filled example 2 — Kiro v3 `UserPromptSubmit` (memory-recall precedent; exposes Kiro-specific traps)

```
trigger:          UserPromptSubmit
cli:              kiro-v3
fires-when:       user submits a prompt, before the model processes it
matcher:          regex against prompt text (per docs) — BUT see edge-cases
stdin-schema:     {session_id, cwd} ONLY (metadata-only). prompt field is EMPTY on stdin (D12)
stdout/exit:      exit 0 → STDOUT appended to model context (inject); exit 2 → blocks prompt,
                   STDERR→LLM; other → warning to user, prompt proceeds
blocking?:        yes (exit 2)
inject?:          raw-stdout-to-context (NOT structured additionalContext like Claude)
failure-handling: timeout=60s default (0 disables) → hook killed; nonzero-non-2 → user warning,
                   proceeds; non-JSON stdout is fine (raw text is the injection payload)
test-tier:        T1 (kiro-memory-recall bin, `echo '{"session_id","cwd"}' | kiro-memory-recall`,
                   80-test bun suite + module-eval), T3 (kiro-memory-hitl.sh live TUI, tokens)
edge-cases:       (1) prompt EMPTY on stdin → cannot query-on-prompt; seed from now.md instead;
                   (2) hook does NOT fire in subagents; (3) v3 workspace-local real-file only
                   (store symlink + global ~/.kiro/hooks ignored); (4) matcher-vs-empty-stdin:
                   docs say matcher tests prompt text yet stdin carries no prompt → VERIFY whether
                   the matcher is evaluated server-side against text the hook never sees
```

---

## 6. Verification tiers — answering "can `nix flake check` still cover token-burning hooks?"

**Yes for the contract and the wiring; no for live firing.** Three tiers, precedent-backed:

- **T1 — hermetic contract test (in `nix flake check`).** Feed a synthetic stdin payload, stub external tools, assert stdout/exit. No CLI, no tokens. Precedent: `checks/validate-at-stop.nix` (5 branch tests, stub `prek`), the 80-test Kiro distiller bun suite, `checks/module-eval.nix` kiro-memory tests. This should cover **every** typed event's wrapper logic and is the default gate.
- **T2 — eval-materialization test (in `nix flake check`).** Assert the typed option renders the correct `settings.json`/`hooks.json` envelope. No CLI. Precedent: `module-eval.nix:700-714` (settings.hooks→upstream route), `:1044-1055` (`hasInfix ''"trigger":"Stop"''` on emitted hook JSON). Covers wiring _shape_ and HM↔devenv parity.
- **T3 — env-gated live test (NOT in default flake check).** Drive a real headless `claude -p` / `kiro-cli --v3` in a scratch repo and assert the event actually fired with the expected stdin. This **burns tokens / needs auth**. Precedent: the validate-at-stop POC (`prek-stop-hook-validator.md:29-35`) and `dev/scripts/kiro-memory-hitl.sh`. **Recommendation:** expose as a flake app (`nix run .#hooks-live`) or `devenv tasks run test:hooks-live`, gated behind an env var (e.g. `AI_HOOKS_LIVE=1`), runnable manually or on a CI cron — never wired into `nix flake check`.

So `nix flake check` covers T1+T2 for every event hermetically (the contract _and_ the rendered wiring); only the "does the CLI truly fire it" assertion needs the env-gated T3 app/task. This is a clean answer to the open question and needs no derivation-level auth hackery.

---

## 7. Recommended phasing

**PoC (de-risk the whole pipeline on a minimal high-leverage set; Claude-primary):**

- Type exactly the events the three plans + in-flight work need: **`Stop`, `PostToolUse`, `UserPromptSubmit`, `SessionStart`** (+ `PreToolUse` if gating is in the first cut). This covers memory write+inject, telemetry turn/tool count, turn-min inject, and the shipped validate-at-stop.
- Model the output contract for these four: `additionalContext` inject + `decision:block`/`reason` (+ `permissionDecision` if PreToolUse is in).
- **Unify HM and devenv behind ONE typed `ai.claude.hooks` event schema**, keep script-body `hooks`/`hooksDir` but _link_ them; fix the `//`-merge bug (§2).
- Type the Kiro v3 envelope for the same four + `Manual` (autoMemory already uses exactly these), emitting real-file workspace-local delivery.
- **Generalize `autoMemory.nix` into the typed surface as the reference consumer** — it proves inject works on both CLIs and validates the whole design end-to-end.
- Ship T1 contract check per event + T2 materialization check + one T3 env-gated live task.

**Full coverage:** type the remaining Claude events (the ~30-event surface — `PostToolBatch`, `SubagentStart/Stop`, `SessionEnd`, `PreCompact/PostCompact`, `Notification`, `StopFailure`, `PermissionRequest`, `FileChanged`, `CwdChanged`, `Task*`, `Elicitation*`, …) and remaining Kiro triggers (`PreToolUse`, `PostToolUse`, `PreTaskExec`, `PostTaskExec`, `PostFile*`); model per-event matcher semantics and the Kiro `agent` action type; implement composition (list-append + dedup) and the hook merge policy (§4.5). Keep freeform passthrough as the escape hatch for exotic/newly-shipped events. Kiro v2 = code stubs only.

**Docs/failure-handling hardening pass:** fill the §5 contract for every event × CLI; add failure-handling tests (timeout, nonzero-non-2 exit, malformed JSON stdout); document edge cases (Kiro subagent no-fire, TUI-vs-headless, workspace-local discovery, Claude `effort.level` presence, matcher-vs-empty-stdin on Kiro UserPromptSubmit); re-verify the exotic Claude stdout field names against the live doc; publish the T3 live matrix.

---

## 8. Decisions the human must make

See structured decisions. In short: (1) how wide to type the Claude surface (subset now vs ~30 events); (2) keep freeform passthrough forever as an escape hatch (recommend yes); (3) whose schema is canonical for HM↔devenv parity — adopt upstream devenv's `hookType` submodule and back-port, or define our own richer schema (that models inject/decision/Kiro) and translate to both (recommend own); (4) live-test token budget (manual-only vs CI-cron); (5) accept the Kiro subagent telemetry/memory blind spot or work around it; (6) fold the shipped Kiro autoMemory into the new typed surface now, or leave it and build Claude memory alongside.
