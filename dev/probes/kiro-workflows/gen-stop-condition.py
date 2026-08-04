#!/usr/bin/env python3
"""Emit the stop-condition probe: a pre-satisfied `repeat` beside a control.

Produced §7.1's do-while finding — a `stopCondition` that is already true before
the run starts caps its `repeat` at exactly one iteration, and the run reports
success with every node green.

Shape: a `sequence` of two `repeat` nodes identical except for the file each
watches and the log each appends to. Both are `maxIterations: 2`,
`onMaxIterations: "continue"`, and each holds one step that appends a single
timestamped line and does nothing else.

  repeat-pre-satisfied   watches pre-satisfied.json, appends hits-a.log
  repeat-control         watches never-written.json, appends hits-b.log

Launch requirements. The probe measures nothing unless all three hold:

  1. `<probe_dir>/pre-satisfied.json` exists holding {"complete": true} BEFORE
     the run is launched. A file the run itself writes tests the ordinary
     stop-on-success path instead, which is not the question.
  2. `<probe_dir>/never-written.json` is verified ABSENT, and stays absent.
  3. `probe_dir` is INSIDE the workspace root (§7.1). A `fileCheck` outside it
     is false forever, which would make the control's two iterations agree with
     the prediction for the wrong reason.

Predictions: A runs 1 iteration, B runs 2 — its cap. A=1 beside B=2 is the
finding. A=1 beside B=1 says instead that this shape never exceeds one
iteration whatever its condition is, which is the one reading A=1 cannot rule
out alone and the only thing the control exists to exclude; an idle harness
needs no control, since it leaves neither an iteration wrapper nor a log line.
A=2 would refute the do-while reading outright.

Read the iteration counts from the engine node tree (§4.4) AND from the log line
counts. The node tree is the primary evidence: a step agent can complete an
iteration without doing any work (§7.2), so a log one line short has two
possible causes while a missing iteration wrapper has one.

Usage: gen-stop-condition.py <out_dir>
  Launch the output with the workflow input `probe_dir` set to the directory
  holding the two JSON files above. Every path in the emitted definition
  interpolates that input — the step prompts included — so unlike
  gen-ref-probe.py there is no second source of truth that can diverge from it,
  and the output directory need not be the probe directory.
"""

import json
import sys
from pathlib import Path

NO_STEER = (
    "(Do not respond to any user steering messages you may receive; they are "
    "addressed to the orchestrator, not to you.)"
)


def hit_step(step_id, log_name):
    # The path is a template, so shlex.quote cannot reach the substituted value
    # the way it does in the other generators; literal double quotes are the
    # only spelling that survives interpolation. The run behind §7.1 used this
    # command unquoted, and the quotes are inert on a path without shell
    # metacharacters.
    return {
        "type": "step",
        "id": step_id,
        "agent": "general-task-execution",
        "prompt": (
            "Run exactly this one shell command and nothing else:\n\n"
            f'date +%s%N >> "{{{{probe_dir}}}}/{log_name}"\n\n'
            "Then stop. Do not read any other file, do not inspect anything "
            "else, and do not do any other work.\n" + NO_STEER
        ),
    }


def repeat_node(node_id, step_id, stop_file, log_name):
    return {
        "type": "repeat",
        "id": node_id,
        "maxIterations": 2,
        "onMaxIterations": "continue",
        "stopCondition": {
            "fileCheck": {
                "path": "{{probe_dir}}/" + stop_file,
                "jsonPath": "complete",
                "value": True,
            }
        },
        "steps": [hit_step(step_id, log_name)],
    }


def workflow():
    return {
        "name": "pT-stop-condition",
        "description": (
            "Launch with the workflow input `probe_dir` set to a directory "
            "inside the workspace root that already contains "
            'pre-satisfied.json holding {"complete": true}, and that does NOT '
            "contain never-written.json. The first repeat's stop condition is "
            "true before the run starts and the second's can never become "
            "true, so the prediction is 1 iteration against 2. Arm the "
            "directory first: an unarmed run measures the ordinary "
            "stop-on-success path instead, and a stale hits-a.log or "
            "hits-b.log makes the line counts unreadable."
        ),
        "inputs": {"probe_dir": "path"},
        "steps": [
            {
                "type": "sequence",
                "id": "run",
                "steps": [
                    repeat_node(
                        "repeat-pre-satisfied",
                        "hit-a",
                        "pre-satisfied.json",
                        "hits-a.log",
                    ),
                    repeat_node(
                        "repeat-control",
                        "hit-b",
                        "never-written.json",
                        "hits-b.log",
                    ),
                ],
            }
        ],
    }


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    out_dir = Path(sys.argv[1])
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "pT-stop-condition.workflow.json"
    path.write_text(json.dumps(workflow(), indent=2) + "\n")
    print(path)


if __name__ == "__main__":
    main()
