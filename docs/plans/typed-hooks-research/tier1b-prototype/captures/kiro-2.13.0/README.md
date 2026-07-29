# Tier-2 live captures — Kiro CLI 2.13.0

Real hook `stdin` payloads captured from a **live Kiro v3 TUI session** on
2026-07-20 (HITL probe, session `sess_a44bce46-…`). Each file is the exact JSON
Kiro piped to a hook for that trigger — primary-source evidence for the Tier-1b
`capture→replay` fixtures (see `../../README.md` and assessment §9/§12).

These are **raw captures, not fixtures.** A fixture wraps one of these payloads
with `expect` assertions + a hook-under-test (that authoring step is the groomed
backlog — do not build them all out here). `cwd` is spliced to `@CWD@` when a
payload becomes a side-channel fixture.

## What the capture settled (resolves §12 Q4 [U]s)

| Trigger            | Payload keys (2.13.0)                                         | Note                                                                             |
| ------------------ | ------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| `SessionStart`     | `session_id, hook_event_name, cwd`                            | metadata-only                                                                    |
| `Stop`             | `session_id, hook_event_name, cwd`                            | metadata-only — **no** `assistant_response` field at all                         |
| `UserPromptSubmit` | `session_id, hook_event_name, cwd, prompt`                    | `prompt` present but **empty** in this capture (probe sent no text on that turn) |
| `PreToolUse`       | `session_id, hook_event_name, cwd, tool_name, tool_input`     | full tool intent — richest guard surface                                         |
| `PostToolUse`      | above **+** `tool_response` (stdout + exit code, stringified) | enables result-aware fixtures                                                    |

Two triggers documented in the assessment did **not** fire in this probe and
remain open (backlog): `Manual` (the `/remember` slash path — Q2) and the
file-lifecycle set (`PostFileSave` etc., `documentedAbsent` in the trigger
sidecar).

> Re-capture on each Kiro bump and diff against these — a changed key set is a
> stdin-schema drift that would silently break hooks (exactly the empty-`prompt`
> class of regression the fixtures guard against).
