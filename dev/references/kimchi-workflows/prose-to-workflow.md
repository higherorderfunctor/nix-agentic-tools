# From prose to a running multi-agent workflow

Read-only research, 2026-10-03. **OBSERVED** means read in source or official
public documentation; it does not mean tested. **INFERRED** means a proposed
integration or conclusion from those paths. No workflows were executed.

Sources: Kimchi 1.5.1 (`66c56747f92285f6bc6865e40e2c1e78c63cc51b`), workflows
0.0.9 (`7a6765ccc4aa417f38cecce1216dd8dcd3b9fab7`), KiroCrew
(`57bc97130ec238e742f1b1da7d5e428648dcabbd`), Kiro's installed 2.27.1 bundle,
and current Claude docs. Kimchi pins workflows 0.0.9 and PI 0.85.1 in
[package.json:53–55][kp]; npm's [release metadata][npm] identifies the workflow
revision. Checkouts/downloads are under this report's `src/` directory.

## Comparison

Rows are **OBSERVED** unless marked otherwise; headless means no terminal UI.

| Harness                  | Prose → plan mechanism                                                                    | Artifact format                                                      | Who launches it                                                  | Per-node model pin                      | Per-node effort pin                                                             | Headless support                                                          | Validation                                                                         |
| ------------------------ | ----------------------------------------------------------------------------------------- | -------------------------------------------------------------------- | ---------------------------------------------------------------- | --------------------------------------- | ------------------------------------------------------------------------------- | ------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| Kimchi + workflows 0.0.9 | Attended goal/interview/design/approval; or model authors TS directly [K4]                | TS default-exported definition + test [K1, K4]                       | Human slash command; model can shell out (**INFERRED**) [K2, K3] | `model`, workflow `defaultModel` [K1]   | No field/plumbing [K1]                                                          | `kimchi -p '/workflow run …'`; human-input steps block [K3]               | TypeScript, runtime load, TypeBox I/O, executable test checks [K4]                 |
| kiro-crew                | Model-callable `workflow_run(intent=…)`; tool-less author session retries generation [R1] | Python `META` + async `workflow(ctx)`; JSON run/library records [R2] | Model MCP call → gateway background runner [R1]                  | `ctx.agent(..., model=...)` wired [R3]  | `effort=` accepted but ignored by both shipped adapters [R3]                    | API-only server present; workflow use without dashboard **INFERRED** [R4] | Syntax/AST/name/DSL checks, up to 3 author attempts, recheck at execution [R1, R5] |
| Kiro built-in 2.27.1     | `run_workflow(workflowPrompt=…)` internally runs creator [B1]                             | Validated JSON; existing recipes also JSON/YAML [B1, B2]             | Top-level model tool call [B1]                                   | Step `modelId` > workflow > parent [B2] | Step `effortLevel` > workflow > parent; unsupported levels reconciled [B2]      | ACP host path observed; CLI headless lifecycle unverified [B1]            | Schema/tree/references validation before persistence and launch [B3]               |
| Claude Code              | Model writes JS and calls `Workflow` [C1]                                                 | JS literal `meta` + orchestration body [C2]                          | Model tool call, background runtime [C1]                         | Agent `model` option [C1]               | Per-agent effort documented; exact workflow-call option needs confirmation [C3] | `-p` / SDK supported; explicit request + tool permission [C1, C2]         | Script syntax/meta checks; structured-output schema checks and retries [C2]        |

**OBSERVED [K1]:** The TypeScript API exposes `createWorkflow`, `createStep`,
`createAgentStep`, `createQuestionnaireStep`, and `createInteractiveStep`.
Builder operations include `then`, `map`, `branch`, `dowhile`, `dountil`,
`foreach`, `parallel`, and nested `workflow`. Step types are function, agent,
questionnaire, interactive; graph nodes are step, branch, loop, foreach,
parallel, nested workflow (`types.ts:332–364`; [API reference][api]).

**OBSERVED [K1]:** Model resolution is `step.model ?? state.defaultModel`, then
host/session fallback. The host resolves exact `provider/modelId` strings; it
does not parse thinking suffixes. Neither agent/workflow options nor the
engine's agent request exposes thinking/effort. Kimchi has a session-level
`--thinking` flag, but spawned workflow agents do not receive it. **INFERRED:**
session thinking may affect in-session agents; that is not a per-node pin, and
appending `:high` to a workflow model string is not supported by this resolver.
[K1, `cli-args.ts:124–127`][thinking]

**OBSERVED [K2, K3]:** Launch surfaces are:

- `/workflow run <name|file.ts> [--input <json>|@file]`; `/workflow create` runs
  the built-in authoring workflow. Bare `/workflow` selects/lists workflows.
- Programmatic `runWorkflow(workflow, initialInput, host, options)` returns
  `Promise<RunResult>`. The host supplies agent execution, clock/sleep, IDs and
  an event sink. Host exports also expose command handlers, stores and bridge.
- `kimchi -p '/workflow run <file>'` and print-mode piped prompts dispatch the
  registered slash command before model input; the command awaits engine
  execution. This route is source-supported, not live-tested here.
- The standalone `kimchi-workflows` executable only has `verify`, no `run` verb.
  The event bus emits telemetry; no workflow launch subscriber is registered.
  The extension registers no model-callable launch tool. Step subprocesses
  deliberately register result/question tools rather than `/workflow`.

**OBSERVED [K3]:** Headless execution can finish **blocked** when a step needs
human input. PI print-mode exit status derives from an assistant stop reason,
not a structured workflow success result. **INFERRED:** an automation must read
run status/event records rather than treat process exit zero as workflow
success.

### How `/workflow create` converts prose into a file

**OBSERVED [K4]:** This is itself a built-in workflow:

1. Collect the goal through a questionnaire; an asking design agent clarifies
   behavior, resolves a collision-free target, and produces a reviewable plan.
2. Render the plan and loop over approval/revision. Headless plan review writes
   the plan but returns no approval when UI is unavailable.
3. Reserve the approved file atomically, prepare the private workflow package
   and lockfile, and have an implementation agent write workflow source and a
   happy-path test.
4. Independently check TypeScript, real runtime loading, reviewed name/input
   conformance and the submitted test. Loop through repairs, then report the
   created artifact. The resulting user workflow is not automatically launched.

**INFERRED [K4]:** The interview is a helpful human authoring path, not a
one-call unattended prose → run endpoint. A model can instead use the public API
reference as authoring context and supply the missing launch action.

## Kimchi: shortest viable paths, ranked by implementation effort

All designs below are **INFERRED**; their enabling/blocking facts are
**OBSERVED**.

1. **Skill + existing shell tool; no engine patch.** Teach the model to turn the
   request into a `.workflow.ts` default export, write an executable test,
   verify it, then invoke `kimchi -p '/workflow run <file> --input …'`.
   **Blocker:** executable/auth/package resolution, result inspection, and
   unattended steps; `/workflow create` cannot supply interactive approval in
   headless mode. This gives the model a launch capability through bash, even
   though it still lacks a native workflow tool. [K1–K4]
2. **Small PI tool wrapping that headless invocation.** Register a
   model-callable `run_workflow` with file/input parameters; spawn Kimchi,
   collect run ID/status, and return structured results. **Blocker:** implement
   process lifecycle, cancellation and progress/final delivery. A background
   wrapper must preserve ownership until completion. Existing slash dispatch and
   child-process agent execution are available; outbound telemetry alone does
   not start runs. [K2, K3]
3. **Deferred same-session command wrapper.** PI 0.85.1 exposes
   `sendUserMessage(content, {expandPromptTemplates: true})`, which enables
   slash dispatch; it defaults false. **Blocker:** defer until the current
   model/tool turn settles. Workflow in-session agents need that same session,
   and the bridge rejects overlapping active in-session steps. Do not
   synchronously await them from a tool already executing in the same turn. This
   requires a live lifecycle probe; workflow dev PI 0.84.1 differs from shipped
   0.85.1. [K3]
4. **Native host launcher plus prose-authoring service.** Reuse loader/store/
   engine/agent bridge behind a PI tool; optionally add a creator agent that
   validates and repairs TS before launching. **Blocker:** safe session
   ownership, durable run tracking, validation errors, creator context and
   completion notifications. This is the closest counterpart to Kiro/Claude, but
   exceeds the minimum needed to launch model-authored TS. [K2, K4, B1, R1]

**Separate required addition for explicit per-node effort:** add thinking/effort
through agent options → step definition → agent request → host bridge; use the
PI thinking setter for in-session agents and `--thinking` for subprocesses.
Define defaults, model compatibility and session restoration. A skill or launch
wrapper cannot provide a field absent from the workflow engine. **INFERRED
[K1].**

**OBSERVED [R1–R5]:** [KiroCrew][crew]'s MCP `workflow_run(intent=…)` posts to
`/api/workflows/run_intent`; the gateway returns a run ID and authors/executes
in the background. A fresh tool-less `kirocrew-lite` session generates Python,
retrying up to three times with validation feedback. Python uses `ctx.agent`,
`parallel`/`pipeline`; run/library JSON persists source/revisions. AST checks
precede restricted-global execution. API-only operation exists (**INFERRED:** no
dashboard needed, but gateway/session services still required). Neither
production adapter honors `effort=`. The builtin app's `/run` stub is not proof
of model execution. Untested by us. [R3–R5]

**OBSERVED [B1–B3]:** Kiro's top-level model sends a self-contained
`workflowPrompt`; `run_workflow` dispatches the bundled creator, which submits
JSON to `save_workflow_definition`, repairs errors, then returns `WORKFLOW_REF`,
`INPUTS`, `SUMMARY`. The same tool creates/invokes the run. Creation blocks
inside the call; execution subsequently runs in the background with
notifications. Nested/delegated launches are refused. Nodes are `step`,
`sequence`, `repeat`, `parallel`, `watch`. Model and effort cascade from step to
workflow to parent. Unsupported effort falls back; a model pin is not a
guarantee of supported effort. Validation checks schema, IDs, limits and
producer/reference ordering. Creator steering says omit pins unless requested,
with mechanical-effort exceptions.

**OBSERVED [B1]:** A small steering/source discrepancy: steering says generated
refs are consumed when the run starts. The handler's invoke-failure message says
the ref was consumed when the run was **created**. **INFERRED:** recovery
guidance should distinguish failed creation from failed invocation; probe before
relying on relaunch-by-ref after an invoke failure.

**OBSERVED, official docs [C1–C3]:** Claude writes JS and passes it to
`Workflow`; `agent()` creates workers, `parallel()` joins concurrent work, and
`pipeline()` streams items through stages. The runtime persists scripts and runs
them in the background. Nodes can select models; per-agent effort is documented,
but the fetched official pages do not explicitly spell out workflow `agent()`'s
effort option. Treat exact per-call syntax as unconfirmed here. Headless
`-p`/SDK launches use normal tool permission evaluation. The keyword trigger is
restricted to human-origin input; a plain workflow request still works in the
SDK. Syntax, literal metadata and structured output are checked. This comparison
is doc-only; no Claude implementation claims are made.

## Open questions requiring a live probe

- **Kimchi:** prove one small unattended model-authored TS workflow runs through
  `-p`, pins two distinct models, and yields inspectable terminal status; test
  invalid source/auth/model and blocked-input outcomes. [K1–K3]
- **Kimchi:** measure session-thinking inheritance/restoration versus background
  subprocess defaults; determine whether any provider supports an alternate
  explicit effort transport without modifying this API. [K1]
- **Kimchi:** test the deferred same-session wrapper's turn ownership, progress,
  cancellation and notification behavior; do not infer safety from command
  routing alone. [K3]
- **Crew:** exercise real `workflow_run(intent=…)`, API-only lifecycle and model
  overrides; confirm the documented effort no-op in both adapters. [R1, R3–R5]
- **Kiro:** test CLI headless completion ownership, unsupported pins and
  generated ref recovery after creation versus invocation failure. [B1–B3]
- **Claude:** confirm exact `agent()` effort syntax/current allowed values from
  its authoring reference and inspect an emitted script. [C2, C3]

## Evidence index

`K*` paths are relative to [workflow revision][wf]; `R*` to [Crew
revision][crew].

- **K1:** [API reference][api]; `src/flow/types.ts:332–364`,
  `src/flow/create-agent-step.ts:20–71`, `src/flow/create-workflow.ts:56–57`;
  `src/engine/step-runner.ts:380,411–429`;
  `src/host/pi-agent-messages.ts:27–34`; `src/host/pi-agent.ts:404–413,605–622`.
- **K2:** `src/host/extension.ts:39–105`; `src/engine/run-workflow.ts:13–18`;
  `src/engine/types.ts:396–413`; `src/host/index.ts:14–28`;
  `bin/kimchi-workflows.mjs:7–8`; `src/verification/cli.ts:10–16`;
  `README.md:134`.
- **K3:** `src/host/extension.ts:9–13`; `src/host/commands/run.ts:225–253`;
  `src/host/commands/attended.ts:67–101`; `src/host/pi-agent.ts:388–401`; Kimchi
  `src/cli.ts:783,840–842`. Exact [PI 0.85.1 archive][pi], locally
  `src/pi-0.85.1/dist/main.js:790–794`, `dist/modes/print-mode.js:103–128`,
  `dist/core/agent-session.js:821–834,1159,1183–1185`.
- **K4:** `src/host/builtin/create.workflow.ts:98–209,211–367,147–150,274–301`.
- **R1:** `src/kiro_crew/mcp_tools/workflows.py:287–300`;
  `src/kiro_crew/workflows/service.py:110–195,888–910,965–1038,1054–1075,1098–1123`.
- **R2:** `docs/system-specs/modules/workflows.md:738–743,841–864`.
- **R3:** `src/kiro_crew/workflows/agent_exec.py:167–182`;
  `docs/system-specs/modules/workflows.md:157–165`.
- **R4:** `src/kiro_crew/dashboard/server.py:7161–7185,7471–7484`.
- **R5:** `src/kiro_crew/workflows/validate.py:796–830`;
  `src/kiro_crew/workflows/runner.py:849–871,920–932`;
  `docs/system-specs/modules/workflows.md:1371–1375` (stub limitation).
- **B1:** [Decoded steering:10–15,39,79–81,109–120][steering]; installed **KAS**
  `acp-server.js:16300–16312,16392` (`RunWorkflowTool.handlePromptArm`,
  including `workflowNew`/`workflowInvoke`).
- **B2:** KAS `acp-server.js:1822` (schema),
  `11605–11635,11735–11741,11776–11783` (creator guidance), `12386` (`JU`, `Nwt`
  cascade), `1911` (`zOn` effort reconciliation).
- **B3:** KAS `acp-server.js:12048–12065` (creator save/repair protocol),
  `16472–16481` (validation), `16494` (`SaveWorkflowDefinition.handle`,
  validation then persistence).
- **C1:** [Official cookbook: introduction, anatomy, script
  primitives][cookbook].
- **C2:** [Official workflow docs: saved script, validation, headless
  permissions][claude]; [Workflow tool inputs][sdk].
- **C3:** [Official per-agent configuration, model and effort fields][agents];
  [workflow prompt caching][cache] distinguishes agents by model/effort. These
  do not independently document the exact workflow-call effort option.

**KAS absolute file:**
`~/.local/share/kiro-cli/kas/2.27.1-<hash>/node_modules/@kiro/agent/dist/server/acp-server.js`.
Kiro evidence is distributed JS.

[kp]:
  https://github.com/getkimchi/kimchi/blob/66c56747f92285f6bc6865e40e2c1e78c63cc51b/package.json#L53
[npm]: https://registry.npmjs.org/@kimchi-dev/kimchi-workflows/0.0.9
[wf]:
  https://github.com/getkimchi/kimchi-workflows/tree/7a6765ccc4aa417f38cecce1216dd8dcd3b9fab7
[api]:
  https://github.com/getkimchi/kimchi-workflows/blob/7a6765ccc4aa417f38cecce1216dd8dcd3b9fab7/docs/api-reference.md
[thinking]:
  https://github.com/getkimchi/kimchi/blob/66c56747f92285f6bc6865e40e2c1e78c63cc51b/src/cli-args.ts#L124
[pi]:
  https://registry.npmjs.org/@earendil-works/pi-coding-agent/-/pi-coding-agent-0.85.1.tgz
[crew]:
  https://github.com/kirodotdev/KiroCrew/tree/57bc97130ec238e742f1b1da7d5e428648dcabbd

[steering]: Kiro 2.27.1 orchestration steering (decoded from the KAS bundle; see
#2221):10 [cookbook]:
https://platform.claude.com/cookbook/claude-agent-sdk-08-dynamic-workflows
[claude]: https://code.claude.com/docs/en/workflows [sdk]:
https://code.claude.com/docs/en/agent-sdk/typescript#workflow [agents]:
https://code.claude.com/docs/en/agent-sdk/subagents#agentdefinition-configuration
[cache]: https://code.claude.com/docs/en/workflows#prompt-caching-in-a-fan-out
