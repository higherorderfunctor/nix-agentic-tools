# Routing behavior evaluations

This manual suite tests planning decisions against the real delivered
delegate-routing skill and applicable always-on rules. It does not execute the
fictional tasks or prove runtime capabilities. `cases.nix` uses the existing
module harness and `runtimes.<runtime>` configuration; expected decisions remain
separate from the prompt. The only five suite files are this guide, the cases,
answer schema, prose rubric, and Python runner.

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

All four adapters (Claude, Codex, Kimchi, Kiro) are disabled with
`UNSUPPORTED_SAFE_PLAN_MODE`. No authenticated suppression preflight or terminal
transcript has established safe tool-free operation. This includes Claude:
documented suppression flags alone do not establish completion capture or
effective isolation. The runner rejects a live request before starting a model
process. `--runtime`, `--model`, and `--effort` identify the evaluator,
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
skill's "Runs own subagents" column. Comparable percentage fixtures use equal
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
