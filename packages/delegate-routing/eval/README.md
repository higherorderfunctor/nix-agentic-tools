# Routing behavior evaluations

This manual suite tests planning decisions against the real delivered
delegate-routing skill and applicable always-on rules. It does not execute the
fictional tasks or prove runtime capabilities. `cases.nix` uses the existing
module harness and `runtimes.<runtime>` configuration; expected decisions remain
separate from the prompt. The isolated set uses the cases, answer schema and
prose rubric. The separate vendor set retains the host system prompt and
repository configuration.

Run from the repository root, with Nix and Python's `jsonschema` installed:

```bash
python3 packages/delegate-routing/eval/run.py --render-only --case all --repeat 3 --seed 42 --out /tmp/delegate-routing-eval/rendered
python3 packages/delegate-routing/eval/run.py --grade-existing /tmp/delegate-routing-eval/answers.json --case all --repeat 3 --seed 42 --out /tmp/delegate-routing-eval/graded
```

`--case` selects case IDs; `all` selects the complete suite. `--repeat` defaults
to three independent trials. The recorded seed shuffles scheduled trials.
`--out` defaults to a fresh directory outside the repository. Use separate
directories for comparisons; preserve failed trials instead of retrying until
they pass. `--fixtures` accepts previously exported fixture JSON for offline
replay. Without it, the runner evaluates the package check's `cases` passthru
through Nix. Rendering may realize generated Markdown, but it starts no model.

## Adapter status and cost

All four isolated adapters (Claude, Codex, Kimchi, Kiro) are disabled with
`UNSUPPORTED_SAFE_PLAN_MODE`. No authenticated suppression preflight or terminal
transcript has established safe tool-free operation. This includes Claude:
documented suppression flags alone do not establish completion capture or
effective isolation. The isolated runner rejects a live request before starting
a model process. `--runtime`, `--model`, and `--effort` identify the evaluator,
separately from the fictional plan's selected model.

Before enabling an adapter, verify empty tool access, blocked tool and child
requests, context isolation, auth preservation, terminal completion capture,
timeout, and output caps for the exact runtime/version/config. Save that
preflight identity and transcript. Read-only permissions and a planning prompt
do not suppress paid tool or child calls. Use a fresh directory outside every
checkout and the raw executable when wrappers force integrations on. Do not copy
credentials into results. Live runs require explicit authorization; one 25-case
run with three repeats schedules 75 candidate turns, plus calibrated prose judge
turns. Never start them from a Nix check.

## Saved answers

`--grade-existing` takes a JSON manifest. Answer paths are relative to the
manifest. Each answer file contains exactly one JSON object; fences, surrounding
text, duplicate keys, and repaired JSON do not count as a valid answer.

```json
{
  "evaluator": {
    "effort": "medium",
    "model": "synthetic-evaluator",
    "runtime": "claude",
    "version": "offline-fixture"
  },
  "trials": [
    {
      "answer": "answer.json",
      "caseId": "user-model-effort",
      "trial": 1
    }
  ]
}
```

Use `infrastructureError` in a trial when no completed candidate answer exists.
Missing scheduled answers remain infrastructure errors, not behavioral passes.
The manifest describes saved evidence; grading does not invoke its evaluator.
The runner saves inputs, observations, exact verdicts, provenance, and summary
JSON/Markdown. Mock usage executables print fixed fixture data and exit; only
the runner executes them. Fictional launcher availability is scenario data.

## Reading results

Exact checks compare complete selection tuples, then validate supplied
inventory, pinning, technique availability, dependency graphs, completion
ownership, review identities, and usage placement. Alternate tuples describe
actual policy choices, not independent field allowances. Native Claude model
aliases map to the supplied concrete synthetic inventory.

Behavioral rates exclude infrastructure errors; end-to-end rates include all
scheduled trials. Invalid candidate JSON is a behavioral failure. Selection
distributions retain allowed alternatives. Prose scoring stays pending until a
calibrated, pinned judge is available; apply `rubric.md` manually to saved text
in the meantime. Combined exact-plus-prose success must not silently count
pending prose as passing.

Missing-usage fallback is unresolved. That case checks honest uncertainty and no
fabricated allowance, while final-pool expectations stay pending. Its repeat
variants cover nonzero helper exit and incomplete successful JSON. Synthetic
child-support observations cover external ownership without depending on the
parallel capability-column change. Comparable percentage fixtures use equal
window durations and reset times; they make no claim about live pool
comparability.

Compare prose revisions with the same fixtures, evaluator, adapter
configuration, judge, seed, and repeat count. Three trials provide an early
signal. Increase to ten for unstable or disputed cases; a model/backend change
is a separate comparison. Render-only success proves fixture assembly, not
routing behavior.

## Auth-free structural gate

`checks.x86_64-linux.delegate-routing-eval-structure` evaluates the cases,
renders every skill and rule, validates the JSON Schema, and checks that
expected fields exist in that schema. It does not run a candidate or judge, and
does not enforce expected model decisions. Home Manager/devenv delivery parity
remains covered by the package's existing module checks.

```bash
python3 packages/delegate-routing/eval/run.py --validate-fixtures --fixtures /tmp/delegate-routing-eval/cases.json
NIX_CONFIG=$'max-jobs = 1\ncores = 2' nix build .#checks.x86_64-linux.delegate-routing-eval-structure --no-link
```

## Vendor steering set: real harness

`--set vendor` evaluates `vendor-cases.nix` through `dev/ai.nix` and the real
devenv delivery pipeline. Six cases cover Claude Opus with the delegation-clamp
hook on/off, Claude ultracode with Pool drain on/off, and Kiro single/dependent
tasks. The Pool drain off variant is observational; no pool preference is
imposed. Clamp cases supply greater Claude headroom so the house pool rule does
not route around native Claude delegation. Ultracode cases supply greater Codex
headroom. Clamp variants require a delegate plan or observed denied delegate
attempt; single Kiro tasks require exactly one delegate; dependent tasks require
a workflow. Pool drain on requires an external Codex delegate or Codex lane.
Each variant gets its own pass/fail and the summary retains the paired
observations. Expected answers never enter the prompt.

Render every variant without an authenticated model turn:

```bash
python3 packages/delegate-routing/eval/run.py --set vendor --render-only --repeat 1 --out /tmp/vendor-render
```

Each trial's `launch.json` records the exact argv, cwd and environment override.
Stdout prints that argv and the complete `config.json` content, including every
generated file and the safety overlay. The workspace contains real generated
instructions, skill and hooks, rather than replacing the vendor system prompt.
Usage is explicitly mocked in the prompt; real usage helpers are never run. The
routing skill is supplied verbatim in the prompt because reads are denied. This
extra exposure is an observed context source and differs from ordinary lazy
skill loading.

Render-only records runtime version as UNKNOWN because it does not invoke a
runtime. Live capture queries `--version` before any turn and records its
executable, version, date, argv, generated-config and effective-config hashes.
Generated sources carry hashes; raw symlinks are preserved, including dangling
references whose targets are recorded as unavailable. The supplied prompt and
safety hook are separately identified. Configured hook payloads are recorded as
configured, not proof of injection. Model-reported context sources are retained
in the answer. User-global/managed configuration, plugins, resolved Kiro
model/effort and hidden vendor steering remain UNKNOWN unless exposed by the
transcript. In particular, a delegation result cannot prove that heron_brook was
present.

The safety overlay exposes native tools but denies all execution through a
logging PreToolUse hook, plus noninteractive permission denial. Claude loads
project settings plus mandatory managed settings, so user-settings hooks cannot
reverse its clamp toggle. Claude MCP enablement is disabled for the evaluation;
Kiro trusts no tools. The real Claude mitigation hook remains installed. Native
tool requests and external launcher calls in shell requests are recorded in
`attempts.json`. A plan is graded separately from attempted calls; a refused
attempt remains evidence, not successful delegation.

Live adapters require suppression and terminal-capture evidence for the
installed runtime and exact generated configuration. Before enabling a manual
run, verify denial of native delegates, workflows, external launchers and
read/write tools, hook execution and terminal completion with the same flags.
Save the transcript outside the repository. Supply a JSON array of preflight
records with `runtime`, `version`, `executable`, `generatedConfigHash`,
`safetyProfileHash`, `allToolsDenied: true`, `hookExecutionVerified: true`,
`terminalCaptureVerified: true`, and `evidenceTranscript` pointing at that file.
The safety-profile hash normalizes the trial directory so evidence can be reused
across repeat directories. Do not assert these fields without observing them. No
paid preflight or model turn is part of the structural checks.

After those checks and explicit authorization, run manually:

```bash
python3 packages/delegate-routing/eval/run.py --set vendor --allow-paid --safety-preflight /tmp/vendor-preflight.json --repeat 1 --out /tmp/vendor-live
```

This schedules six paid candidate turns (18 at the default three repeats), with
no judge or delegate turns. Real vendor prompts, repository instructions and
Opus ultracode can make these considerably more expensive than isolated cases;
no fixed monetary cost is claimed. Failed turns retain transcripts and
infrastructure errors. Unsupported Kiro stream formats or missing completion
markers are infrastructure errors rather than inferred passes. Render-only
proves assembly, not safety or vendor behavior.

`checks.x86_64-linux.delegate-routing-vendor-structure` validates the vendor
fixtures and renders every variant with no runtime process, authentication or
behavioral assertions.
