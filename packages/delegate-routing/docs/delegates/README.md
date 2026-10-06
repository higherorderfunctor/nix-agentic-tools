# Delegate reference

How Claude Code, Codex, Kiro and Kimchi start, control and prompt their
delegates, at pinned versions. Use it to decide what a normalized delegation
option can promise in each harness, and what would have to move outside them.
Every fact cell carries an evidence mark. Probe scripts for replay live in
`packages/delegate-routing/probes/delegates/<harness>/`.

## Files

| Topic            | File                                       | Answers questions like                                                           |
| ---------------- | ------------------------------------------ | -------------------------------------------------------------------------------- |
| Delegate tools   | [tools.md](tools.md)                       | What starts a delegate? Max depth? Max concurrency? Workflows?                   |
| Lifecycle        | [lifecycle.md](lifecycle.md)               | Can I steer, cancel, resume or time out a running child?                         |
| Control surfaces | [control-surfaces.md](control-surfaces.md) | Which config key, flag, env var or patch sets model, effort, tools, permissions? |
| System prompt    | [system-prompt.md](system-prompt.md)       | What prompt does each delegate kind get? Which append channel reaches it?        |
| Evidence         | [evidence.md](evidence.md)                 | How was each row proven? How do I rerun it after a version bump?                 |

## Headline facts

| Topic                      | Claude Code                                 | Codex                                        | Kiro                                          | Kimchi                                          |
| -------------------------- | ------------------------------------------- | -------------------------------------------- | --------------------------------------------- | ----------------------------------------------- |
| Model-callable sub-agent   | `Agent` (V)                                 | V2 `spawn_agent`; V1 legacy (V)              | v2 `subagent` crew; v3 `invoke_sub_agent` (V) | `Agent` (V)                                     |
| Workflows                  | `Workflow` tool, main only (V)              | none (V)                                     | v3 `run_workflow`, gated (V)                  | `/workflow run`, user/host only (V)             |
| Max depth                  | 3 below main, env-tunable (V)               | V1 1; V2 no cap (V)                          | v2 1; v3 rejects ≥5 (V)                       | 1; workflow bg step 2 (V)                       |
| Concurrency                | 20; excess refused, not queued (V)          | config; V2 counts root (V)                   | v3 5 per execution; v2 U                      | bg 4 then queue; fg uncapped (V)                |
| Per-child model            | param, frontmatter, env (V)                 | spawn arg or role (V)                        | v3 agent, inline, step (V)                    | tool param; frontmatter ignored (V)             |
| Per-child effort           | frontmatter only; no per-call param (V)     | spawn arg or role (V)                        | v3 yes; v2 none sent (V)                      | tool `thinking`; workflow step none (V)         |
| Steer running child        | bg via `SendMessage`; fg and node no (V)    | V2 followup/send; host steer rejected (V)    | v3 parent steer leaks in; no per-child (V)    | bg `steer_subagent`; fg no (V)                  |
| Cancel propagates          | yes, to fg grandchild (V)                   | V2 no; V1 close cascades (V; A)              | v3 yes, whole turn only; v2 no (V)            | fg yes; bg no via RPC/ACP (V)                   |
| Update running child       | U                                           | no (V)                                       | no; next turn only (V)                        | no (V)                                          |
| Headless child permissions | error or auto-deny, no hang (V)             | inherits parent; approval to host (V)        | rejected unless trusted (V)                   | child ungated; workflow forced yolo (V)         |
| Delegate wall clock        | none; `maxTurns`, stall env (V)             | none; key is a no-op (G)                     | 1 h idle env, 300 turns; no total (V)         | 900 s default, 120 s idle (V)                   |
| Extra system text          | main + separate sub-agent channel (V)       | `developer_instructions`; top layer wins (V) | steering, user-role before prompt (V)         | `--append-system-prompt`; children get none (V) |
| Protocol host              | SDK stream-json, `mcp serve`; no ACP (V; G) | `app-server`; no MCP or ACP (V)              | ACP (V)                                       | RPC and ACP; no MCP server (V; A)               |

One normalized extra-prompt option: main and headless YES; protocol, sub-agent
and workflow kinds PARTIAL; side turns (title, compaction) NO (V). Details in
[system-prompt.md](system-prompt.md).

## Pinned versions

| Harness     | Version                                              |
| ----------- | ---------------------------------------------------- |
| Claude Code | 2.1.289                                              |
| Codex CLI   | 0.160.0                                              |
| Kiro CLI    | 2.27.1 (KAS 0.66.22; default engine v2, v3 opt-in)   |
| Kimchi      | 1.5.1 / Pi 0.85.1 (patched) / kimchi-workflows 0.0.9 |

A version bump makes that harness's rows unverified until its probes rerun; see
[evidence.md](evidence.md).

## Evidence marks

- **V** — executed against the binary (capture mock, fake provider or live).
- **Vr** — executed the extracted bundle function (system-prompt rows only).
- **A** — read from the parsed source (AST).
- **G** — found by grep or `--help` text; not executed.
- **I** — inferred from code; not executed.
- **U** — unknown; the open question is listed in the topic file.
- **SPLIT** — investigators disagreed and the judge could not settle it. None
  remain at these pins.
