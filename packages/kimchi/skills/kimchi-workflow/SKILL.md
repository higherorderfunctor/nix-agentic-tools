---
name: kimchi-workflow
description:
  Author and launch a Kimchi workflow from a headless Kimchi session's bash
  tool, then read its durable result. Use for ordered or parallel workflow steps
  that need a real output or human-input status.
---

Run from the project root with its configured `kimchi` on PATH. This route was
measured on 2026-10-04 with Kimchi 1.5.1, model `kimchi-dev/glm-5.3-flash`, the
real home and a `kimchi -p` parent session; `run-completed` was observed.
Interactive use is unverified.

Author an absolute-path `*.workflow.ts` with a default committed workflow.
Consult the upstream package's `README.md`, `docs/`, and `examples/` in
`.kimchi/workflows/node_modules/@kimchi-dev/kimchi-workflows` once prepared.
Minimal agent workflow (replace the model and result contract for the task):

```typescript
import { createAgentStep, createWorkflow } from "@kimchi-dev/kimchi-workflows";
import { Type } from "typebox";

export default createWorkflow({ name: "answer" })
  .then(
    createAgentStep({
      name: "answer",
      maxDurationMs: 90000,
      maxOutputRepairs: 0,
      maxTokens: 50000,
      model: "kimchi-dev/glm-5.3-flash",
      output: Type.Object({ marker: Type.Literal("ok") }),
      prompt: () => 'Call workflow_submit_result with {"marker":"ok"}.',
    }),
  )
  .commit();
```

With the **bash tool**, explicitly set `timeout: 600` (seconds), increasing it
for longer work. Resolve `SKILL_DIR` to the directory containing this SKILL.md:

```bash
"$SKILL_DIR/bin/kimchi-workflow-run" --model kimchi-dev/glm-5.3-flash /absolute/answer.workflow.ts
```

Optional `--input '{"key":"value"}'` or `--input @/absolute/input.json` seeds a
workflow with a matching input schema. Pin each agent step's model too; the
launcher's required `--model` pins the child session. The launcher appends
`extensions.workflows` to `KIMCHI_ENABLE_RESOURCES`, preserves HOME/XDG, uses
`--thinking off`, closes stdin, and captures both streams in a fresh session.
Persistent resource disable settings can override environment enablement. First
use may require network for corepack/pnpm project package preparation. A
foreground agent step inherits the full context (about 32k tokens per probe).

Read the launcher's JSON, never Kimchi's exit code or assistant prose:

- `completed`: use `output`; verify the resulting artifact when applicable.
- `blocked`: `error.requests` contains pending questionnaires/interactions and
  their `path`, excluding opaque conversation history; report the human-input
  request with `runId` and `sessionDir`.
- `crashed` / `cancelled`: report `error` and evidence paths.
- `in_progress` after child exit: failed/abandoned; never claim completion.
- `failed`: no record, ambiguous records, or invalid record; report `error`.

Only `completed` exits zero. JSON includes `runId`, `status`, `output` or
`error`, `sessionDir`, and `eventsFile`. Keep that evidence. If the bash timeout
interrupts the launcher, use its stderr `sessionDir` receipt to inspect the
record **after the child has exited**:
`"$SKILL_DIR/bin/kimchi-workflow-run" --read-session /absolute/session-dir`. Do
not relaunch a workflow with side effects just to obtain a result.
